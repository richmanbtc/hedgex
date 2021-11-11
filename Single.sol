//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;
import "./interfaces/AggregatorV3Interface.sol";
import "./interfaces/IERC20.sol";
import "./libraries/TransferHelper.sol";
import "./HedgexERC20.sol";

/// @title Single pair hedge pool contract
contract HedgexSingle is HedgexERC20 {
    //确保交易时效性，秒数时间戳
    /*
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "HedgexSingle: EXPIRED");
        _;
    }
    */

    uint256 private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, "hedgex locked");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    struct Trader {
        int256 margin; //保证金
        uint256 longAmount; //多仓持仓量
        uint256 longPrice; //多仓持仓金额
        uint256 shortAmount; //空仓持仓量
        uint256 shortPrice; //空仓持仓金额
    }

    //各种费率计算时的除数常数
    uint24 public constant divConst = 1000000;

    //保证金池最小量，合约的启动最小值，注意精度
    uint256 public immutable minPool;

    //对冲合约是否已经启动
    bool public isStart;

    //杠杆率
    uint8 public immutable leverage;

    //单笔交易数量限制，对冲池净值比例，3%
    uint16 public constant singleTradeLimitRate = 30000;

    //成交价格的偏移设定值，买入时增加，卖出时减少，此数为万分比
    uint8 public constant slideP = 50;

    //是否开启手续费收取
    bool public feeOn;

    //手续费费率，真实计算的时候用此值除以divConst
    uint16 public constant feeRate = 600;

    //运营平台对手续费的分成比例，真实计算的时候用此值除以divConst
    uint24 public constant feeDivide = 250000;

    //运营平台收取的手续费总量
    uint256 public sumFee;

    //每天利息惩罚率，真实计算的时候用此值除以divConst
    uint16 public constant dailyInterestRateBase = 1000;

    //利息分成比例，真实计算的时候用此值除以divConst
    uint24 public constant interestRewardRate = 100000;

    //token0 是保证金的币种
    address public immutable token0;
    //token0 代币精度，已变换10的次方
    uint256 public immutable token0Decimal;
    //对冲池中token0的总量，可以为负值
    int256 public totalPool;

    //开仓量精度或者最小开仓量，此代表10的x次方，比如每张合约对应0.001个btc，则此值为-3
    int8 public immutable amountDecimal;
    //总池的多仓持仓量和空仓持仓量，单位为“张”
    uint256 public poolLongAmount;
    uint256 public poolShortAmount;
    //总池的多仓价格和空仓价格，单位为“wtoken0/张”，也就是每张合约的价值为token0个代币乘以token0的精度
    uint256 public poolLongPrice;
    uint256 public poolShortPrice;

    //所有的交易者
    mapping(address => Trader) public traders;

    //获取价格的合约地址
    AggregatorV3Interface public immutable feedPrice;
    //获取到的合约价格精度
    uint256 public immutable feedPriceDecimal;

    event Mint(address indexed sender, uint256 amount); //增加流动性
    event Burn(address indexed sender, uint256 amount); //移除流动性
    event Recharge(address indexed sender, uint256 amount); //充值保证金
    event Withdraw(address indexed sender, uint256 amount); //提取保证金
    event Trade(
        address indexed sender,
        int8 direction, //开多、开空、平多、平空，分别为1，-1，-2，2
        uint256 amount,
        uint256 price
    ); //用户下达交易
    event Explosive(
        address indexed user,
        int8 direction, //爆仓方向，-2表示多仓爆仓，2表示空仓爆仓
        uint256 amount,
        uint256 price
    ); //爆仓事件
    event TakeInterest(
        address indexed user,
        int8 direction,
        uint256 amount,
        uint256 price
    ); //收取利息，price为持仓价，amount为收取的利息量

    /*
        _token0, 保证金代币的合约地址
        _feedPrice, 交易对价格获取地址
        _feedPriceDecimal，上一个地址获取到的价格精度，对于usd来说为100000000
        _minStartPool，最小启动金额，注意精度，1000000*(10^6)是100万usdt
        _leverage，合约执行中的杠杆倍数
        _amountDecimal，开仓量精度或者最小开仓量，此代表10的x次方        
        //0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 ETH mainnet eth/usd price
        //0x8A753747A1Fa494EC906cE90E9f37563A8AF630e rinkeby net eth/usd price
        //0xcf0f51ca2cDAecb464eeE4227f5295F2384F84ED rinkeby chainlink bnb/usd price, decimal:8
    */
    constructor(
        address _token0,
        address _feedPrice,
        uint256 _feedPriceDecimal,
        uint256 _minStartPool,
        uint8 _leverage,
        int8 _amountDecimal
    ) HedgexERC20(IERC20(_token0).decimals()) {
        feedPrice = AggregatorV3Interface(_feedPrice);
        token0 = _token0;
        token0Decimal = 10**(IERC20(_token0).decimals());
        feedPriceDecimal = _feedPriceDecimal;
        minPool = _minStartPool;
        leverage = _leverage;
        isStart = false;
        feeOn = false;
        amountDecimal = _amountDecimal;
    }

    function initialize(
        address _token0,
        address _feedPrice,
        uint256 _feedPriceDecimal,
        uint256 _minStartPool,
        uint8 _leverage,
        int8 _amountDecimal
    ) external {}

    //向对冲池中增加token0的流动性
    //amount, token0的总量
    //to 用户lp token的接收地址，新产生的lp会发送到此地址
    function addLiquidity(uint256 amount, address to) external {
        //向合约地址发送token0代币，需要提前调用approve授权，要授权给合约地址token0的数量
        TransferHelper.safeTransferFrom(
            token0,
            msg.sender,
            address(this),
            amount
        );

        uint256 liquidity = amount; //合约在未启动状态下1:1兑换代币
        if (isStart) {
            //如果合约已经启动，根据当前净值，计算需要发行多少lp代币，净值小于等于0时，不能操作！
            int256 net = getPoolNet();
            liquidity = (totalSupply * amount) / uint256(net);
        }

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
    //liquidity, 发送到合约地址的lp代币数量
    //to, token0代币的接收地址
    function removeLiquidity(uint256 liquidity, address to) external {
        uint256 amount = liquidity;
        if (isStart) {
            uint256 price = getLatestPrice();
            int256 net = getPoolNet(price);
            //用净头寸计算已用保证金
            uint256 netAmount = poolLongAmount > poolShortAmount
                ? (poolLongAmount - poolShortAmount)
                : (poolShortAmount - poolLongAmount);
            uint256 usedMargin = (netAmount * price); //此处不用除以杠杆率
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
    //amount, 发送到池中的token0代币数量
    function rechargeMargin(uint256 amount) public {
        //向合约地址发送token0代币，需要提前调用approve授权
        TransferHelper.safeTransferFrom(
            token0,
            msg.sender,
            address(this),
            amount
        );
        traders[msg.sender].margin += int256(amount);
        emit Recharge(msg.sender, amount);
    }

    //用户提取保证金
    function withdrawMargin(uint256 amount) external {
        Trader memory t = traders[msg.sender];

        //当前价格
        uint256 price = getLatestPrice();
        //当前已占用保证金
        uint256 usedMargin = ((t.longAmount + t.shortAmount) * price) /
            leverage;
        //计算当前净值
        int256 net = t.margin +
            int256(t.longAmount * price + t.shortAmount * t.shortPrice) -
            int256(t.longAmount * t.longPrice + t.shortAmount * price);

        int256 canWithdrawMargin = net - int256(usedMargin);
        require(canWithdrawMargin > 0, "can withdraw is negative");
        uint256 maxAmount = amount;
        if (int256(amount) > canWithdrawMargin) {
            maxAmount = uint256(canWithdrawMargin);
        }
        traders[msg.sender].margin = t.margin - int256(maxAmount);
        TransferHelper.safeTransfer(token0, msg.sender, maxAmount);
        emit Withdraw(msg.sender, maxAmount);
    }

    //开仓做多
    //priceExp，期望价格，如果为0，表示按市价成交
    //amount，开仓量，单位为张
    //rechargeAmount, 转入的保证金量
    function openLong(
        uint256 priceExp,
        uint256 amount,
        uint256 rechargeAmount
    ) public {
        uint256 indexPrice = getLatestPrice();
        uint256 openPrice = (indexPrice * (divConst + slideP)) / divConst;
        require(
            openPrice <= priceExp || priceExp == 0,
            "open long price is too high"
        );
        require(isStart, "contract is not start");
        // 转入保证金
        if (rechargeAmount > 0) {
            rechargeMargin(rechargeAmount);
        }

        Trader memory t = traders[msg.sender];
        uint256 money = amount * openPrice;
        uint256 fee = judegOpen(t, indexPrice, amount, money);

        traders[msg.sender].longAmount = t.longAmount + amount;
        traders[msg.sender].longPrice =
            (t.longAmount * t.longPrice + money) /
            (t.longAmount + amount);
        traders[msg.sender].margin = t.margin - int256(fee);

        uint256 _amount = poolShortAmount;
        poolShortAmount = _amount + amount;
        poolShortPrice =
            (_amount * poolShortPrice + money) /
            (_amount + amount);

        feeCharge(fee);
        emit Trade(msg.sender, 1, amount, openPrice);
    }

    //开仓做空
    //priceExp，期望价格，如果为0，表示按市价成交
    //amount，开仓量，单位为张
    //rechargeAmount, 转入的保证金量
    function openShort(
        uint256 priceExp,
        uint256 amount,
        uint256 rechargeAmount
    ) public {
        uint256 indexPrice = getLatestPrice();
        uint256 openPrice = (indexPrice * (divConst - slideP)) / divConst;
        require(openPrice >= priceExp, "open short price is too low");

        require(isStart, "contract is not start");
        if (rechargeAmount > 0) {
            rechargeMargin(rechargeAmount);
        }

        Trader memory t = traders[msg.sender];
        uint256 money = amount * openPrice;
        uint256 fee = judegOpen(t, indexPrice, amount, money);

        traders[msg.sender].shortAmount = t.shortAmount + amount;
        traders[msg.sender].shortPrice =
            (t.shortAmount * t.shortPrice + money) /
            (t.shortAmount + amount);
        traders[msg.sender].margin = t.margin - int256(fee);

        uint256 _amount = poolLongAmount;
        poolLongAmount = _amount + amount;
        poolLongPrice = (_amount * poolLongPrice + money) / (_amount + amount);

        feeCharge(fee);
        emit Trade(msg.sender, -1, amount, openPrice);
    }

    //平多仓
    //amount单位为“张”
    function closeLong(uint256 priceExp, uint256 amount) public {
        uint256 indexPrice = getLatestPrice();
        uint256 closePrice = (getLatestPrice() * (divConst - slideP)) /
            divConst;
        require(closePrice >= priceExp, "close long price is lower");
        Trader memory t = traders[msg.sender];
        uint256 fee = judgeClose(indexPrice, closePrice, amount, t.longAmount);

        int256 profit = int256(amount) *
            (int256(closePrice) - int256(t.longPrice));
        traders[msg.sender].longAmount = t.longAmount - amount;
        traders[msg.sender].margin = t.margin + profit - int256(fee);
        if (t.longAmount == amount) {
            traders[msg.sender].longPrice = 0;
        }
        poolShortAmount -= amount;

        feeCharge(fee, profit);
        emit Trade(msg.sender, -2, amount, closePrice);
    }

    //平空仓
    //amount单位为“张”
    function closeShort(uint256 priceExp, uint256 amount) public {
        uint256 indexPrice = getLatestPrice();
        uint256 closePirce = (indexPrice * (divConst + slideP)) / divConst;
        require(
            closePirce <= priceExp || priceExp == 0,
            "close short price is higher"
        );
        Trader memory t = traders[msg.sender];
        uint256 fee = judgeClose(indexPrice, closePirce, amount, t.shortAmount);

        int256 profit = int256(amount) *
            (int256(t.shortPrice) - int256(closePirce));
        traders[msg.sender].shortAmount = t.shortAmount - amount;
        traders[msg.sender].margin = t.margin + profit - int256(fee);
        if (t.shortAmount == amount) {
            traders[msg.sender].shortPrice = 0;
        }
        poolLongAmount -= amount;

        feeCharge(fee, profit);
        emit Trade(msg.sender, 2, amount, closePirce);
    }

    //爆仓
    function explosive(address account) public {
        Trader memory t = traders[account];

        uint256 keepMargin = (t.longAmount *
            t.longPrice +
            t.shortAmount *
            t.shortPrice) / 30;
        uint256 price = getLatestPrice();
        int256 net = getAccountNet(t, price);
        require(net <= int256(keepMargin), "Can not be explosived");

        //对冲池多空仓减掉相应数量
        if (t.longAmount > 0) {
            poolShortAmount -= t.longAmount;
        }
        if (t.shortAmount > 0) {
            poolLongAmount -= t.shortAmount;
        }

        int8 direction = -2;
        if (t.longAmount < t.shortAmount) {
            direction = 2;
        }

        //用户账户所有数值清空
        traders[account].margin = 0;
        traders[account].longAmount = 0;
        traders[account].longPrice = 0;
        traders[account].shortAmount = 0;
        traders[account].shortPrice = 0;

        if (net > 0) {
            TransferHelper.safeTransfer(token0, msg.sender, uint256(net));
        } else {
            totalPool += net;
        }
        emit Explosive(account, direction, t.longAmount + t.shortAmount, price);
    }

    //利息收取
    function detectSlide(address account) public {
        uint256 price = getLatestPrice();
        Trader storage t = traders[account];
        require(t.longAmount != t.shortAmount, "need long and short not equal");

        uint256 _shortPosition = poolShortAmount;
        uint256 _longPosition = poolLongAmount;
        uint256 interest = 0;
        int8 direction = 1;
        if (t.longAmount > t.shortAmount) {
            require(_shortPosition > _longPosition, "have no interest");
            interest =
                (price *
                    t.longAmount *
                    dailyInterestRateBase *
                    (_shortPosition - _longPosition)) /
                divConst /
                _shortPosition;
        } else {
            require(_longPosition > _shortPosition, "have no interest");
            direction = -1;
            interest =
                (price *
                    t.shortAmount *
                    dailyInterestRateBase *
                    (_longPosition - _shortPosition)) /
                divConst /
                _longPosition;
        }
        uint256 reward = (interest * interestRewardRate) / divConst;
        t.margin -= int256(interest);
        totalPool += int256(interest) - int256(reward);
        TransferHelper.safeTransfer(token0, msg.sender, reward);

        emit TakeInterest(account, direction, interest, price);
    }

    //获取当前对冲池的净值，数值为token0的带精度数量
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

    //判定用户开仓条件
    function judegOpen(
        Trader memory t,
        uint256 indexPrice,
        uint256 amount,
        uint256 money
    ) internal view returns (uint256) {
        limitTradeAmount(indexPrice, amount);
        //用户净值
        int256 net = t.margin +
            int256(t.longAmount * indexPrice + t.shortAmount * t.shortPrice) -
            int256(t.longAmount * t.longPrice + t.shortAmount * indexPrice);
        //已占用保证金量
        uint256 usedMargin = ((t.longAmount + t.shortAmount) * indexPrice) /
            leverage;
        //所需保证金
        uint256 needMargin = money / leverage;
        //所需手续费
        uint256 fee = (money * feeRate) / divConst;
        //可用保证金
        int256 canUseMargin = net - int256(usedMargin) - int256(fee);
        require(canUseMargin > 0, "left margin is equal or less than 0");
        require(uint256(canUseMargin) >= needMargin, "margin is not enough");
        return fee;
    }

    //判断用户平仓条件
    //price，当前价格
    //closeAmount，平仓量
    //openAmount，已开仓量
    function judgeClose(
        uint256 indexPrice,
        uint256 closePrice,
        uint256 closeAmount,
        uint256 openAmount
    ) internal view returns (uint256) {
        limitTradeAmount(indexPrice, closeAmount);
        require(closeAmount <= openAmount, "position not enough");
        return (closeAmount * closePrice * feeRate) / divConst;
    }

    //限制用户开平仓量
    function limitTradeAmount(uint256 price, uint256 amount) internal view {
        int256 net = getPoolNet(price);
        require(
            amount <=
                ((uint256(net) * singleTradeLimitRate) / divConst) / price,
            "amount over net*rate"
        );
    }

    //对冲池结算手续费
    function feeCharge(uint256 fee) internal {
        if (feeOn) {
            uint256 platFee = (fee * feeDivide) / divConst;
            sumFee += platFee;
            totalPool += int256(fee) - int256(platFee);
        } else {
            totalPool += int256(fee);
        }
    }

    //对冲池结算手续费和利润
    function feeCharge(uint256 fee, int256 profit) internal {
        if (feeOn) {
            uint256 platFee = (fee * feeDivide) / divConst;
            sumFee += platFee;
            totalPool += int256(fee) - int256(platFee) - profit;
        } else {
            totalPool += int256(fee) - profit;
        }
    }

    function getAccountNet(Trader memory t) internal view returns (int256) {
        uint256 price = getLatestPrice();
        return
            t.margin +
            int256(t.longAmount * price + t.shortAmount * t.shortPrice) -
            int256(t.longAmount * t.longPrice + t.shortAmount * price);
    }

    function getAccountNet(Trader memory t, uint256 price)
        internal
        pure
        returns (int256)
    {
        return
            t.margin +
            int256(t.longAmount * price + t.shortAmount * t.shortPrice) -
            int256(t.longAmount * t.longPrice + t.shortAmount * price);
    }

    //获取交易对价格
    //此价格为真实价格乘以交易对定价币的精度，比如wusdt为10的6次方usdt
    //再进行每张合约价格的核算，乘以10^amountDecimal
    //最后数值为，每张合约的定价币带精度价格
    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , , ) = feedPrice.latestRoundData();
        require(price > 0, "the pair standard price must be positive");
        if (amountDecimal >= 0) {
            return
                (uint256(price) * token0Decimal * 10**uint8(amountDecimal)) /
                feedPriceDecimal;
        }
        return
            (uint256(price) * token0Decimal) /
            10**uint8(-amountDecimal) /
            feedPriceDecimal;
    }
}
