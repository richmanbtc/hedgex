//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;
import "./interfaces/AggregatorV3Interface.sol";
import "./interfaces/IERC20.sol";
import "./libraries/TransferHelper.sol";
import "./HedgexERC20.sol";

/// @title Single pair hedge pool contract
contract HedgexSingle is HedgexERC20 {
    address public feeTo;
    address public feeToSetter;
    address internal newFeeToSetter;

    uint8 public poolState; //合约状态，1：正常运行，2：pool处于爆仓状态
    uint256 public poolExplosivePrice; //合约爆仓价格，爆仓时锁定此价格
    uint24 public constant poolLeftAmountRate = 50000; //爆仓时，pool净值如果小于此比例，则按照此比例推算爆仓价格
    uint256 public constant foceCloseRewardGas = 1000000000;
    //0.001376BNB 137616 gas
    //0.000869

    uint256 private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, "hedgex locked");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "Hedgex Trade: EXPIRED");
        _;
    }

    struct Trader {
        int256 margin; //保证金
        uint256 longAmount; //多仓持仓量
        uint256 longPrice; //多仓持仓金额
        uint256 shortAmount; //空仓持仓量
        uint256 shortPrice; //空仓持仓金额
        uint32 interestDay; //已经做过利息检测的时间戳，从时间戳0开始的天数
    }

    //各种费率计算时的除数常数
    uint24 public constant divConst = 1000000;

    //保证金池最小量，合约的启动最小值，注意精度
    uint256 public immutable minPool;

    //对冲合约是否已经启动
    bool public isStart;

    //杠杆率
    uint8 public immutable leverage;

    //单笔交易开仓数量限制，对冲池净值比例，3%
    uint16 public constant singleOpenLimitRate = 30000;

    //单笔交易平仓数量限制，对冲池净值比例，10%
    uint24 public constant singleCloseLimitRate = 100000;

    //对冲池净头寸比例，在开仓时的限制边界值
    int24 public constant poolNetAmountRateLimitOpen = 300000;

    //对冲池净头寸比例，开平仓价格偏移的临界值
    int24 public constant poolNetAmountRateLimitPrice = 200000;

    //成交价格的偏移设定值，买入时增加，卖出时减少，此数为万分比
    uint8 public constant slideP = 50;

    //是否开启手续费收取
    bool public feeOn;

    //手续费费率，真实计算的时候用此值除以divConst
    uint16 public constant feeRate = 600;

    //开发运营团队对手续费的分成比例，真实计算的时候用此值除以divConst
    uint24 public constant feeDivide = 250000;

    //开发运营团队收取的手续费总量
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

    //chainlink eth mainnet :
    //      bnbusd : 0x14e613AC84a31f709eadbdF89C6CC390fDc9540A
    //      ethusd : 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
    //chainlink eth rinkeby :
    //      bnbusd : 0xcf0f51ca2cDAecb464eeE4227f5295F2384F84ED
    //      ethusd : 0x8A753747A1Fa494EC906cE90E9f37563A8AF630e
    //chainlink bsc test :
    //      bnbusd : 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526
    address public immutable gasUsdPriceFeed =
        0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526;

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
    event ForceClose(
        address indexed account,
        uint256 long,
        uint256 short,
        uint256 price
    );

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
        poolState = 1;
        feedPrice = AggregatorV3Interface(_feedPrice);
        token0 = _token0;
        token0Decimal = 10**(IERC20(_token0).decimals());
        feedPriceDecimal = _feedPriceDecimal;
        minPool = _minStartPool;
        leverage = _leverage;
        isStart = false;
        feeOn = false;
        amountDecimal = _amountDecimal;

        feeToSetter = msg.sender;
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
        require(poolState == 1, "state isn't 1");
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
        require(poolState == 1, "state isn't 1");
        uint256 amount = liquidity;
        if (isStart) {
            uint256 price = getLatestPrice();
            int256 net = getPoolNet(price);
            //用净头寸计算已用保证金
            uint256 netAmount = poolLongAmount > poolShortAmount
                ? (poolLongAmount - poolShortAmount)
                : (poolShortAmount - poolLongAmount);
            uint256 totalAmount = (poolLongAmount + poolShortAmount) / 3;
            if (netAmount < totalAmount) {
                netAmount = totalAmount;
            }
            uint256 usedMargin = ((netAmount * price) * divConst) /
                uint24(poolNetAmountRateLimitOpen);

            require(net > int256(usedMargin), "net must > usedMargin/R");

            //计算对冲池可提现金额的最大值
            uint256 canWithdraw = uint256(net) - usedMargin;
            amount = (uint256(net) * liquidity) / totalSupply;
            require(amount <= canWithdraw, "withdraw amount too many");
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
        require(poolState == 1, "state isn't 1");
        Trader memory t = traders[msg.sender];

        //当前价格
        uint256 price = getLatestPrice();
        //当前已占用保证金
        uint256 usedMargin = (t.longAmount *
            t.longPrice +
            t.shortAmount *
            t.shortPrice) / leverage;
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
    function openLong(
        uint256 priceExp,
        uint256 amount,
        uint256 deadline
    ) public lock ensure(deadline) {
        require(poolState == 1, "state isn't 1");
        require(isStart, "contract is not start");
        uint256 indexPrice = getLatestPrice();

        //判断净头寸比例是否符合开仓要求
        (int256 R, int256 net) = poolLimitTrade(1, indexPrice);
        require(
            amount <=
                ((uint256(net) * singleOpenLimitRate) / divConst) / indexPrice,
            "single amount over net * rate"
        );
        require(
            R < poolNetAmountRateLimitOpen,
            "pool net amount must small than 30%"
        );

        //叠加价格偏移量
        uint256 openPrice = indexPrice + slideTradePrice(indexPrice, R);
        require(
            openPrice <= priceExp || priceExp == 0,
            "open long price is too high"
        );

        uint256 money = amount * openPrice;
        (uint256 fee, Trader memory t) = judegOpen(indexPrice, money);

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
    function openShort(
        uint256 priceExp,
        uint256 amount,
        uint256 deadline
    ) public lock ensure(deadline) {
        require(poolState == 1, "state isn't 1");
        require(isStart, "contract is not start");
        uint256 indexPrice = getLatestPrice();

        //判断净头寸比例是否符合开仓要求
        (int256 R, int256 net) = poolLimitTrade(-1, indexPrice);
        require(
            amount <=
                ((uint256(net) * singleOpenLimitRate) / divConst) / indexPrice,
            "single amount over net * rate"
        );
        require(
            R < poolNetAmountRateLimitOpen,
            "pool net amount must small than 30%"
        );

        //叠加价格偏移量
        uint256 openPrice = indexPrice - slideTradePrice(indexPrice, R);
        require(openPrice >= priceExp, "open short price is too low");

        uint256 money = amount * openPrice;
        (uint256 fee, Trader memory t) = judegOpen(indexPrice, money);

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
    function closeLong(
        uint256 priceExp,
        uint256 amount,
        uint256 deadline
    ) public lock ensure(deadline) {
        require(poolState == 1, "state isn't 1");
        uint256 indexPrice = getLatestPrice();

        //判断净头寸是否符合平仓要求
        (int256 R, int256 net) = poolLimitTrade(-1, indexPrice);
        require(
            amount <=
                ((uint256(net) * singleCloseLimitRate) / divConst) / indexPrice,
            "single amount over net * rate"
        );

        uint256 closePrice = indexPrice - slideTradePrice(indexPrice, R);
        require(closePrice >= priceExp, "close long price is lower");

        Trader memory t = traders[msg.sender];
        require(t.longAmount >= amount, "close amount require >= longAmount");
        uint256 fee = (amount * closePrice * feeRate) / divConst;

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
    function closeShort(
        uint256 priceExp,
        uint256 amount,
        uint256 deadline
    ) public lock ensure(deadline) {
        require(poolState == 1, "state isn't 1");
        uint256 indexPrice = getLatestPrice();

        //判断净头寸是否符合平仓要求
        (int256 R, int256 net) = poolLimitTrade(1, indexPrice);
        require(
            amount <=
                ((uint256(net) * singleCloseLimitRate) / divConst) / indexPrice,
            "single amount over net * rate"
        );

        uint256 closePrice = indexPrice + slideTradePrice(indexPrice, R);
        require(
            closePrice <= priceExp || priceExp == 0,
            "close short price is higher"
        );

        Trader memory t = traders[msg.sender];
        require(t.shortAmount >= amount, "close amount require >= shortAmount");
        uint256 fee = (amount * closePrice * feeRate) / divConst;

        int256 profit = int256(amount) *
            (int256(t.shortPrice) - int256(closePrice));
        traders[msg.sender].shortAmount = t.shortAmount - amount;
        traders[msg.sender].margin = t.margin + profit - int256(fee);
        if (t.shortAmount == amount) {
            traders[msg.sender].shortPrice = 0;
        }
        poolLongAmount -= amount;

        feeCharge(fee, profit);
        emit Trade(msg.sender, 2, amount, closePrice);
    }

    //爆仓
    function explosive(address account, address to) public lock {
        require(poolState == 1, "state isn't 1");
        Trader memory t = traders[account];

        uint256 keepMargin = (t.longAmount *
            t.longPrice +
            t.shortAmount *
            t.shortPrice) / 30;
        uint256 price = getLatestPrice();
        int256 net = getAccountNet(t, price);
        require(net <= int256(keepMargin), "Can not be explosived");

        int256 profit = 0;
        //对冲池多空仓减掉相应数量
        if (t.longAmount > 0) {
            poolShortAmount -= t.longAmount;
            profit =
                int256(t.longAmount) *
                (int256(price) - int256(t.longPrice));
        }
        if (t.shortAmount > 0) {
            poolLongAmount -= t.shortAmount;
            profit +=
                int256(t.shortAmount) *
                (int256(t.shortPrice) - int256(price));
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
            TransferHelper.safeTransfer(token0, to, uint256(net / 5));
            totalPool += (net * 4) / 5 - profit;
        } else {
            totalPool += net - profit;
        }
        emit Explosive(account, direction, t.longAmount + t.shortAmount, price);
    }

    //利息收取
    function detectSlide(address account, address to) public lock {
        require(poolState == 1, "state isn't 1");
        uint32 dayCount = uint32(block.timestamp / 86400);
        require(
            block.timestamp - uint256(dayCount * 86400) <= 300,
            "time disable"
        );
        Trader storage t = traders[account];
        require(dayCount > t.interestDay, "has been take interest");
        require(t.longAmount != t.shortAmount, "need long and short not equal");

        uint256 price = getLatestPrice();
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
        t.interestDay = dayCount;
        t.margin -= int256(interest);
        totalPool += int256(interest) - int256(reward);
        TransferHelper.safeTransfer(token0, to, reward);

        emit TakeInterest(account, direction, interest, price);
    }

    //对冲池爆仓
    function explosivePool() public lock {
        require(poolState == 1, "pool is explosiving");
        uint256 indexPrice = getLatestPrice();
        int256 poolNet = getPoolNet(indexPrice);
        uint256 keepMargin = poolLongAmount > poolShortAmount
            ? ((poolLongAmount - poolShortAmount) * indexPrice) / 5
            : ((poolShortAmount - poolLongAmount) * indexPrice) / 5;
        //如果pool净值小于等于维持保证金数量，则进入爆仓流程
        require(poolNet <= int256(keepMargin), "pool cann't be explosived");
        poolState = 2; //设定爆仓状态

        //计算爆仓价格
        int256 leftAmount = int256(keepMargin / 4);
        if (poolNet < leftAmount) {
            //预估爆仓价计算
            int256 ePrice = (totalPool -
                int256(poolLongAmount * poolLongPrice) +
                int256(poolShortAmount * poolShortPrice) -
                leftAmount) /
                (int256(poolShortAmount) - int256(poolLongAmount));
            require(ePrice > 0, "eprice > 0");
            poolExplosivePrice = uint256(ePrice);
            totalPool = leftAmount;
        } else {
            totalPool = poolNet;
            poolExplosivePrice = indexPrice;
        }
        poolLongPrice = poolShortPrice = 0;
    }

    //强制按照爆仓价对用户平仓
    function forceCloseAccount(address account, address to) public lock {
        require(poolState == 2, "poolState is not 2");
        Trader memory t = traders[account];
        uint256 _poolExplosivePrice = poolExplosivePrice;
        int256 net = getAccountNet(t, _poolExplosivePrice);

        uint256 fee = ((t.longAmount *
            _poolExplosivePrice +
            t.shortAmount *
            _poolExplosivePrice) * feeRate) / divConst;

        //对冲池多空仓减掉相应数量
        if (t.longAmount > 0) {
            poolShortAmount -= t.longAmount;
        }
        if (t.shortAmount > 0) {
            poolLongAmount -= t.shortAmount;
        }
        //如果所有用户的仓位都平掉了，合约状态从爆仓中恢复
        if (poolLongAmount <= 0 && poolShortAmount <= 0) {
            poolState = 1;
        }

        //用户账户所有数值清空
        if (net > int256(fee)) {
            traders[account].margin = net - int256(fee);
            totalPool += int256(fee);
        } else {
            traders[account].margin = 0;
            totalPool += net;
        }
        traders[account].longAmount = 0;
        traders[account].longPrice = 0;
        traders[account].shortAmount = 0;
        traders[account].shortPrice = 0;

        uint256 reward = (foceCloseRewardGas *
            getGasUsdPrice() *
            token0Decimal) / 100000000000000000000000000;

        totalPool -= int256(reward);
        TransferHelper.safeTransfer(token0, to, reward);

        emit ForceClose(
            account,
            t.longAmount,
            t.shortAmount,
            _poolExplosivePrice
        );
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

    //判断对冲池的开平仓的限制，返回流动池净头寸率
    //d为开仓方向，+1表示开多，-1表示开空
    //inP为指数价格
    //amount为开仓量
    function poolLimitTrade(int8 d, uint256 inP)
        internal
        view
        returns (int256, int256)
    {
        int256 net = getPoolNet(inP);
        return (
            (d *
                (int256(poolShortAmount) - int256(poolLongAmount)) *
                int256(inP) *
                int24(divConst)) / net,
            net
        );
    }

    //计算交易价格的偏移量
    function slideTradePrice(uint256 inP, int256 R)
        internal
        pure
        returns (uint256)
    {
        uint256 slideRate = 0;
        if (R >= (poolNetAmountRateLimitPrice * 3) / 2) {
            slideRate = uint256(
                poolNetAmountRateLimitPrice /
                    10 +
                    (2 * R - 3 * poolNetAmountRateLimitPrice) /
                    5
            );
        } else if (R >= poolNetAmountRateLimitPrice) {
            slideRate = uint256(R - poolNetAmountRateLimitPrice) / 5;
        }
        slideRate = (inP * (slideRate + slideP)) / divConst;
        return slideRate;
    }

    //判定用户开仓条件
    function judegOpen(uint256 indexPrice, uint256 money)
        internal
        returns (uint256, Trader memory)
    {
        Trader memory t = traders[msg.sender];
        //用户净值
        int256 net = t.margin +
            int256(t.longAmount * indexPrice + t.shortAmount * t.shortPrice) -
            int256(t.longAmount * t.longPrice + t.shortAmount * indexPrice);
        //已占用保证金量
        uint256 usedMargin = (t.longAmount *
            t.longPrice +
            t.shortAmount *
            t.shortPrice) / leverage;
        //所需保证金
        uint256 needMargin = money / leverage;
        //所需手续费
        uint256 fee = (money * feeRate) / divConst;
        //需要额外转入的保证金
        int256 needRechargeMargin = int256(usedMargin + needMargin + fee) - net;
        if (needRechargeMargin > 0) {
            rechargeMargin(uint256(needRechargeMargin));
            t = traders[msg.sender];
        }
        return (fee, t);
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

    function getPoolPosition()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (poolLongAmount, poolLongPrice, poolShortAmount, poolShortPrice);
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

    function getGasUsdPrice() public view returns (uint256) {
        (, int256 price, , , ) = AggregatorV3Interface(gasUsdPriceFeed)
            .latestRoundData();
        return uint256(price);
    }

    //提取手续费
    function withdrawFee() external {
        require(msg.sender == feeTo, "hedgex:FORBIDDEN");
        uint256 _sumFee = sumFee;
        sumFee = 0;
        TransferHelper.safeTransfer(token0, feeTo, _sumFee);
    }

    //设置开发运营团队是否收取手续费
    function setFeeOn(bool b) external {
        require(msg.sender == feeToSetter, "hedgex: FORBIDDEN");
        feeOn = b;
    }

    //设置手续费发送地址
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "hedgex: FORBIDDEN");
        feeTo = _feeTo;
    }

    //转移feeToSetter
    function transferFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "hedgex: FORBIDDEN");
        newFeeToSetter = _feeToSetter;
    }

    //接收feeToSetter
    function acceptFeeToSetter() external {
        require(msg.sender == newFeeToSetter, "hedgex: FORBIDDEN");
        feeToSetter = newFeeToSetter;
        newFeeToSetter = address(0);
    }
}
