//SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.7;
import "./interfaces/AggregatorV3Interface.sol";
import "./interfaces/IERC20.sol";
import "./libraries/TransferHelper.sol";
import "./HedgexERC20.sol";

/// @title Single pair hedge pool contract
contract HedgexSingle is HedgexERC20 {
    //函数修改器，确保交易时效性，秒数时间戳
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "HedgexSingle: EXPIRED");
        _;
    }

    struct Swapper {
        int256 margin; //保证金
        uint256 longAmount; //多仓持仓量
        uint256 longPrice; //多仓持仓金额
        uint256 shortAmount; //空仓持仓量
        uint256 shortPrice; //空仓持仓金额
    }

    //各种费率计算时的除数常数
    uint16 constant divConst = 10000;

    //保证金池最小量，合约的启动最小值，注意精度
    uint256 minPool;

    //对冲合约是否已经启动
    bool isStart;

    //the max pool's amount
    uint256 maxPool;

    //杠杆率
    uint8 leverage;

    //每天利息惩罚率，真实计算的时候用此值除以divConst
    uint8 constant dailyInterestRateBase = 10;

    //单笔交易数量限制，对冲池净值比例，3%
    uint16 constant singleTradeLimitRate = 300;

    //是否开启手续费收取
    bool feeOn;

    //手续费费率，真实计算的时候用此值除以divConst
    uint256 constant feeRate = 30;

    //运营平台对手续费的分成比例，真实计算的时候用此值除以divConst
    uint256 feeDivide = 1500;

    //运营平台收取的手续费总量
    uint256 sumFee;

    //对于盈利方，惩罚的利息率，此值除以divConst
    uint256 constant interestRewardRate = 1000;

    //token0 是保证金的币种
    address token0;
    //对冲池中token0的总量，可以为负值
    int256 totalPool;

    //总池的多仓持仓量和空仓持仓量
    uint256 public poolLongAmount;
    uint256 public poolShortAmount;
    //总池的多仓持金额和空仓持金额
    uint256 public poolLongPrice;
    uint256 public poolShortPrice;

    //所有的交易者
    mapping(address => Swapper) public swappers;

    //获取价格的合约地址
    AggregatorV3Interface private priceFeed;

    event Mint(address indexed sender, uint256 amount);
    event Burn(address indexed sender, uint256 amount);
    event Recharge(address indexed sender, uint256 amount);
    event Withdraw(address indexed sender, uint256 amount);

    constructor(address _token0, address _feedPrice) {
        //0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c为ETH网络btc/usd价格
        priceFeed = AggregatorV3Interface(_feedPrice);
        token0 = _token0;
        minPool = 1000000000000000000000000;
        leverage = 8;
        isStart = false;
        feeOn = false;
    }

    //向对冲池中增加token0的流动性
    function addLiquidity(
        uint256 amount, //token0的总量
        address to, //用户lp token的接收地址，新产生的lp会发送到此地址
        uint256 deadline //the deadline timestamp
    ) external ensure(deadline) {
        uint256 liquidity = amount; //合约在未启动状态下1:1兑换代币
        if (isStart) {
            //如果合约已经启动，根据当前净值，计算需要发行多少lp代币，净值小于等于0时，不能操作！
            int256 net = getPoolNet();
            liquidity = (totalSupply * amount) / uint256(net);
        }

        //向合约地址发送token0代币，需要提前调用approve授权
        TransferHelper.safeTransferFrom(
            token0,
            msg.sender,
            address(this),
            amount
        );

        //token0总量增加
        totalPool += int256(amount);
        if (totalPool >= int256(minPool)) {
            isStart = true;
        }
        //产生新的lp代币，发送给流动性提供者
        _mint(to, liquidity);
        emit Mint(msg.sender, liquidity);
    }

    //从总池中移走流动性代币token0
    function removeLiquidity(
        uint256 liquidity, //发送到合约地址的lp代币数量
        address to, //token0代币的接收地址
        uint256 deadline
    ) external ensure(deadline) {
        uint256 amount = liquidity;
        if (isStart) {
            uint256 price = getLatestPrice();
            int256 net = getPoolNet(price);
            //用净头寸计算已用保证金
            uint256 netAmount = poolLongAmount > poolShortAmount
                ? (poolLongAmount - poolShortAmount)
                : (poolShortAmount - poolLongAmount);
            uint256 usedMargin = (netAmount * price) / leverage;
            require(net > int256(usedMargin), "net need be position");

            //计算对冲池可提现金额的最大值
            uint256 canWithdraw = uint256(net) - usedMargin;
            uint256 sNet = uint256(net) / 10;
            if (canWithdraw > sNet) {
                canWithdraw = sNet;
            }
            amount = (uint256(net) * liquidity) / totalSupply;
            require(amount <= canWithdraw, "withdraw amount too much");
        }
        totalPool -= int256(amount);
        _burn(msg.sender, liquidity); //销毁用户lp代币
        TransferHelper.safeTransfer(token0, to, amount); //给用户发送token0代币
        emit Burn(msg.sender, liquidity);
    }

    //增加用户保证金
    function rechargeMargin(
        uint256 amount, //发送到池中的token0代币数量
        uint256 deadline //交易截止时间
    ) external ensure(deadline) {
        //向合约地址发送token0代币，需要提前调用approve授权
        TransferHelper.safeTransferFrom(
            token0,
            msg.sender,
            address(this),
            amount
        );
        swappers[msg.sender].margin += int256(amount);
        emit Recharge(msg.sender, amount);
    }

    //用户提取保证金
    function withdrawMargin(uint256 amount, uint256 deadline)
        external
        ensure(deadline)
    {
        Swapper memory swapper = swappers[msg.sender];

        //当前价格
        uint256 price = getLatestPrice();
        //当前已占用保证金
        uint256 usedMargin = ((swapper.longAmount + swapper.shortAmount) *
            price) / leverage;
        //计算当前净值
        int256 net = getAccountNet(swapper, price);

        int256 canWithdrawMargin = net - int256(usedMargin);
        require(canWithdrawMargin > 0, "can withdraw is negative");
        uint256 maxAmount = amount;
        if (amount > uint256(canWithdrawMargin)) {
            maxAmount = uint256(canWithdrawMargin);
        }

        TransferHelper.safeTransfer(token0, msg.sender, maxAmount);
        emit Withdraw(msg.sender, maxAmount);
    }

    function open(
        int8 direction, //开仓方向
        uint256 priceExp, //预期开仓价格
        uint256 amount //开仓数量
    ) public {
        Swapper memory swapper = swappers[msg.sender];
        uint256 price = getLatestPrice();
        if (direction > 0) {
            require(
                price >= priceExp || priceExp == 0,
                "open long price is higher"
            );
        } else if (direction < 0) {
            require(price <= priceExp, "open short price is lower");
        }
        uint8 _leverage = leverage;

        //账户净值
        int256 net = getAccountNet(swapper, price);
        //占用保证金量
        uint256 usedMargin = ((swapper.longAmount + swapper.shortAmount) *
            price) / leverage;
        int256 canWithdrawMargin = net - int256(usedMargin);
        require(canWithdrawMargin > 0, "can withdraw is negative");

        uint256 money = amount * price;
        uint256 needMargin = money / _leverage;
        uint256 fee = (money * feeRate) / divConst;
        int256 canUseMargin = net - int256(usedMargin) - int256(fee);
        require(int256(needMargin) <= canUseMargin, "margin is not enough");

        if (direction > 0) {
            swappers[msg.sender].longAmount = swapper.longAmount + amount;
            swappers[msg.sender].longPrice =
                (swapper.longAmount * swapper.longPrice + money) /
                (swapper.longAmount + amount);

            uint256 _amount = poolShortAmount;
            uint256 _price = poolShortPrice;
            poolShortAmount = _amount + amount;
            poolShortPrice = (_amount * _price + money) / (_amount + amount);
        } else if (direction < 0) {
            swappers[msg.sender].shortAmount = swapper.shortAmount + amount;
            swappers[msg.sender].shortPrice =
                (swapper.shortAmount * swapper.shortPrice + money) /
                (swapper.shortAmount + amount);

            uint256 _amount = poolLongAmount;
            uint256 _price = poolLongPrice;
            poolLongAmount = _amount + amount;
            poolLongPrice = (_amount * _price + money) / (_amount + amount);
        }

        swappers[msg.sender].margin = swapper.margin - int256(fee);

        if (feeOn) {
            uint256 platFee = (fee * feeDivide) / divConst;
            sumFee += platFee;
            totalPool += int256(fee) - int256(platFee);
        } else {
            totalPool += int256(fee);
        }
    }

    function close(
        int8 direction,
        uint256 priceExp, //wait
        uint256 amount
    ) public {
        uint256 price = getLatestPrice();
        if (direction < 0 && priceExp > 0) {
            require(price >= priceExp, "close short price is higher");
        } else if (direction > 0 && priceExp > 0) {
            require(price <= priceExp, "close long price is lower");
        }
        int256 net = getPoolNet(price);

        require(
            amount <=
                ((uint256(net) * singleTradeLimitRate) / divConst) / price,
            "amount over net*rate"
        );

        Swapper memory swaper = swappers[msg.sender];
        uint256 fee = (amount * price * feeRate) / divConst;
        uint256 _poolFee = fee;
        if (feeOn) {
            uint256 platFee = (fee * feeDivide) / divConst;
            sumFee += platFee;
            _poolFee -= platFee;
        }
        int256 profit = 0;
        if (direction > 0) {
            require(amount <= swaper.longAmount, "long position is not enough");
            profit = int256(amount * price) - int256(amount * swaper.longPrice);
            swappers[msg.sender].longAmount = swaper.longAmount - amount;
            swappers[msg.sender].margin = swaper.margin + profit - int256(fee);

            poolShortAmount -= amount;
        } else if (direction < 0) {
            require(
                amount <= swaper.shortAmount,
                "short position is not enough"
            );
            profit =
                int256(amount * swaper.shortPrice) -
                int256(amount * price);
            swappers[msg.sender].shortAmount = swaper.shortAmount - amount;
            swappers[msg.sender].margin = swaper.margin + profit - int256(fee);

            poolLongAmount -= amount;
        }
        totalPool -= -profit + int256(_poolFee);
    }

    function explosive(address account, address to) public {
        Swapper memory swapper = swappers[account];
        uint256 price = getLatestPrice();

        uint256 keepMargin = ((swapper.longAmount + swapper.shortAmount) *
            price) / 30;
        int256 net = getAccountNet(swapper, price);
        require(net <= int256(keepMargin), "The price is not required");

        //用户账户所有数值清空
        swappers[account].margin = 0;
        swappers[account].longAmount = 0;
        swappers[account].longPrice = 0;
        swappers[account].shortAmount = 0;
        swappers[account].shortPrice = 0;

        //对冲池多空仓减掉相应数量
        if (swapper.longAmount > 0) {
            poolShortAmount -= swapper.longAmount;
        }
        if (swapper.shortAmount > 0) {
            poolLongAmount -= swapper.shortAmount;
        }

        if (net > 0) {
            TransferHelper.safeTransfer(token0, to, uint256(net));
        } else {
            totalPool += net;
        }
    }

    function detectSlide(address account, address to) public {
        uint256 price = getLatestPrice();
        Swapper storage swapper = swappers[account];
        require(
            swapper.longAmount != swapper.shortAmount,
            "need long and short not equal"
        );

        uint256 _shortPosition = poolShortAmount;
        uint256 _longPosition = poolLongAmount;
        uint256 interest = 0;
        if (swapper.longAmount > swapper.shortAmount) {
            require(_shortPosition > _longPosition, "have no interest");
            interest =
                (price *
                    swapper.longAmount *
                    dailyInterestRateBase *
                    (_shortPosition - _longPosition)) /
                divConst /
                _shortPosition;
        } else {
            require(_longPosition > _shortPosition, "have no interest");
            interest =
                (price *
                    swapper.shortAmount *
                    dailyInterestRateBase *
                    (_longPosition - _shortPosition)) /
                divConst /
                _longPosition;
        }
        uint256 reward = (interest * interestRewardRate) / divConst;
        swapper.margin -= int256(interest);
        totalPool += int256(interest) - int256(reward);
        TransferHelper.safeTransfer(token0, to, reward);
    }

    //get the pool's current net
    function getPoolNet() public view returns (int256) {
        uint256 price = getLatestPrice();
        int256 net = totalPool +
            int256(poolLongAmount * price + poolShortAmount * poolShortPrice) -
            int256(poolLongAmount * poolLongPrice + poolShortAmount * price);
        require(net > 0, "net need be position");
        return net;
    }

    //get the pool's current net
    function getPoolNet(uint256 price) internal view returns (int256) {
        int256 net = totalPool +
            int256(poolLongAmount * price + poolShortAmount * poolShortPrice) -
            int256(poolLongAmount * poolLongPrice + poolShortAmount * price);
        require(net > 0, "net need be position");
        return net;
    }

    function getAccountNet(Swapper memory s, uint256 price)
        internal
        pure
        returns (int256)
    {
        return
            s.margin +
            int256(s.longAmount * price + s.shortAmount * s.shortPrice) -
            int256(s.longAmount * s.longPrice + s.shortAmount * price);
    }

    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price > 0, "the pair standard price must be positive");
        return uint256(price);
    }
}
