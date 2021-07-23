//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.2;
import "./interfaces/AggregatorV3Interface.sol";
import "./interfaces/IERC20.sol";
import "./libraries/TransferHelper.sol";
import "./HedgexERC20.sol";

/// @title Single pair hedge pool contract
contract HedgexSingle is HedgexERC20 {
    //define a struct for the hedge swapper
    struct Swapper {
        uint256 margin; // the margin of the user
        uint256 longPosition;
        uint256 longPrice;
        uint256 shortPosition;
        uint256 shortPrice;
    }

    //the min pool's amount
    uint256 minPool;

    //the max pool's amount
    uint256 maxPool;

    //
    uint8 leverage;

    // it is mean x / 10000
    uint8 constant dailyInterestRateBase = 10;

    bool feeOn;

    uint256 sumFee;

    // it is mean x / 10000, for example feeRate = 5, is mean 0.0005
    uint256 feeRate;

    // it is mean x / 10000
    uint256 interestRewardRate = 1000;

    //the current total amount of token0 for pool
    uint256 totalPool;

    //token0 is the coin of margin
    address public token0;

    //the position of the total pool, the direction is negative to the user's total position
    uint256 public longPosition;
    uint256 public shortPosition;

    //the price of the positionPool
    uint256 public longPrice;
    uint256 public shortPrice;

    //all the swappers
    mapping(address => Swapper) public swappers;

    //get the price feed address
    AggregatorV3Interface private priceFeed;

    event Mint(address indexed sender, uint256 amount);
    event Burn(address indexed sender, uint256 amount);
    event Recharge(address indexed sender, uint256 amount);
    event Withdraw(address indexed sender, uint256 amount);

    constructor(
        address _token0,
        address _feedPrice,
        uint256 _minPool,
        uint8 _leverage
    ) public {
        priceFeed = AggregatorV3Interface(_feedPrice);
        token0 = _token0;
        minPool = _minPool;
        leverage = _leverage;
    }

    //add liquidity of token0 to the pool
    function addLiquidityToPool(
        uint256 amount, // the amount of token0 to add the pool
        address to, // the address which the lp token to send
        uint256 deadline // the deadline timestamp
    ) external payable {
        //transfer token to this contract, it need user to approve this contract to tranferfrom the token
        TransferHelper.safeTransferFrom(
            token0,
            msg.sender,
            address(this),
            amount
        );
        int256 net = getPoolNet();
        require(net > 0, "net need be position"); // ???
        uint256 liquidity = (totalSupply * amount) / (uint256(net));
        totalPool += amount;
        _mint(to, liquidity);
        emit Mint(msg.sender, liquidity);
    }

    //remove liquidity of token0 from the pool
    function removeLiquidityFromPool(
        uint256 liquidity,
        address to,
        uint256 deadline
    ) external {
        //send liquidity to this contract
        TransferHelper.safeTransfer(address(this), address(this), liquidity);
        int256 net = getPoolNet();
        require(net > 0, "net need be position"); // ???
        uint256 amount = ((uint256(net)) * liquidity) / totalSupply;
        _burn(address(this), liquidity);
        TransferHelper.safeTransferFrom(token0, address(this), to, amount);
        emit Burn(msg.sender, liquidity);
    }

    function rechargeMargin(
        uint256 amount, // the amount of token0 to add the pool
        uint256 deadline // the deadline timestamp
    ) external payable {
        //transfer token to this contract, it need user to approve this contract to tranferfrom the token
        TransferHelper.safeTransferFrom(
            token0,
            msg.sender,
            address(this),
            amount
        );
        swappers[msg.sender].margin += amount;
        emit Recharge(msg.sender, amount);
    }

    function withdrawMargin(uint256 amount, uint256 deadline) external {
        Swapper memory swaper = swappers[msg.sender];

        //cacculate the net of swaper
        uint256 price = getLatestPrice();

        uint256 useMargin =
            ((swaper.longPosition + swaper.shortPrice) * price) / leverage;

        uint256 net =
            swaper.margin +
                swaper.longPosition *
                (price - swaper.longPrice) +
                swaper.shortPosition *
                (swaper.shortPrice - price);

        uint256 canWithdrawMargin = net - useMargin;
        uint256 maxAmount = amount;
        if (amount > canWithdrawMargin) {
            maxAmount = canWithdrawMargin;
        }

        TransferHelper.safeTransfer(token0, msg.sender, maxAmount);
        emit Withdraw(msg.sender, maxAmount);
    }

    function Open(
        int8 direction,
        uint256 price_exp,
        uint256 amount
    ) public {
        Swapper memory swaper = swappers[msg.sender];
        uint256 price = getLatestPrice();
        uint8 _leverage = leverage;
        uint256 useMargin =
            ((swaper.longPosition + swaper.shortPosition) * price) / _leverage;

        int256 net =
            int256(swaper.margin) +
                int256(swaper.longPosition) *
                int256(price - swaper.longPrice) +
                int256(swaper.shortPosition) *
                int256(swaper.shortPrice - price);

        int256 canUseMargin = net - int256(useMargin);

        int256 canAmount = (canUseMargin * int256(_leverage)) / int256(price);

        require(int256(amount) < canAmount, "margin is not enough");

        if (direction > 0) {
            swappers[msg.sender].longPosition = swaper.longPosition + amount;
            swappers[msg.sender].longPrice =
                (swaper.longPosition * swaper.longPrice + amount * price) /
                (swaper.longPosition + amount);

            uint256 _shortPosition = shortPosition;
            shortPosition = _shortPosition + amount;
            shortPrice =
                (_shortPosition * shortPrice + amount * price) /
                (_shortPosition + amount);
        } else if (direction < 0) {
            swappers[msg.sender].shortPosition = swaper.shortPosition + amount;
            swappers[msg.sender].shortPrice =
                (swaper.shortPosition * swaper.shortPrice + amount * price) /
                (swaper.shortPosition + amount);

            uint256 _longPosition = longPosition;
            longPosition = _longPosition + amount;
            longPrice =
                (_longPosition * longPrice + amount * price) /
                (_longPosition + amount);
        }

        uint256 fee = (amount * price * feeRate) / 10000;
        swappers[msg.sender].margin = swaper.margin - fee;

        if (feeOn) {
            sumFee += fee / 6;
            totalPool += fee - fee / 6;
        } else {
            totalPool += fee;
        }
    }

    function Close(
        int8 direction,
        uint256 price_exp,
        uint256 amount
    ) public {
        uint256 price = getLatestPrice();
        Swapper memory swaper = swappers[msg.sender];
        uint256 fee = (amount * price * feeRate) / 10000;
        uint256 _poolFee = 0;
        if (feeOn) {
            sumFee += fee / 6;
            _poolFee = fee - fee / 6;
        } else {
            _poolFee = fee;
        }
        if (direction > 0) {
            require(
                amount <= swaper.longPosition,
                "long position is not enough"
            );
            uint256 profit = amount * (price - swaper.longPrice);
            swappers[msg.sender].longPosition = swaper.longPosition - amount;
            swappers[msg.sender].margin = swaper.margin + profit - fee;

            uint256 _shortPosition = shortPosition;
            shortPosition = _shortPosition - amount;
            totalPool = totalPool - profit + _poolFee;
        } else if (direction < 0) {
            require(
                amount <= swaper.shortPosition,
                "short position is not enough"
            );
            uint256 profit = amount * (swaper.shortPrice - price);
            swappers[msg.sender].shortPosition = swaper.shortPosition - amount;
            swappers[msg.sender].margin = swaper.margin + profit - fee;

            uint256 _longPosition = longPosition;
            longPosition = _longPosition - amount;
            totalPool = totalPool - profit + _poolFee;
        }
    }

    function explosive(address account, address to) public {
        Swapper memory swaper = swappers[account];
        uint256 price = getLatestPrice();

        uint256 keepMargin =
            ((swaper.longPosition + swaper.shortPosition) * price) / 30;
        int256 net =
            int256(swaper.margin) +
                int256(swaper.longPosition) *
                int256(price - swaper.longPrice) +
                int256(swaper.shortPosition) *
                int256(swaper.shortPrice - price);
        require(net <= int256(keepMargin), "The price is not required");

        if (net > 0) {
            // send the left token0 to the to for regard
            TransferHelper.safeTransfer(token0, to, uint256(net));
        } else {
            totalPool += uint256(net);
        }

        swappers[account].margin = 0;
        swappers[account].longPosition = 0;
        swappers[account].shortPosition = 0;

        if (swaper.longPosition > 0) {
            shortPosition -= swaper.shortPosition;
        }
        if (swaper.shortPosition > 0) {
            longPosition -= swaper.longPosition;
        }
    }

    function detectSlide(address account, address to) public {
        uint256 price = getLatestPrice();
        Swapper storage swaper = swappers[account];
        require(
            swaper.longPosition != swaper.shortPosition,
            "need long and short not equal"
        );

        uint256 _shortPosition = shortPosition;
        uint256 _longPosition = longPosition;
        uint256 interest = 0;
        if (swaper.longPosition > swaper.shortPosition) {
            require(_shortPosition > _longPosition, "have no interest");
            interest =
                (price *
                    swaper.longPosition *
                    dailyInterestRateBase *
                    (_shortPosition - _longPosition)) /
                _shortPosition;
        } else {
            require(_longPosition > _shortPosition, "have no interest");
            interest =
                (price *
                    swaper.shortPosition *
                    dailyInterestRateBase *
                    (_longPosition - _shortPosition)) /
                _longPosition;
        }
        uint256 reward = (interest * interestRewardRate) / 10000;
        swaper.margin -= interest;
        totalPool += interest - reward;
        TransferHelper.safeTransfer(token0, to, reward);
    }

    //get the pool's current net
    function getPoolNet() public returns (int256) {
        uint256 price = getLatestPrice();
        return
            int256(totalPool) +
            int256(longPrice - price) *
            int256(longPosition) +
            int256(price - shortPrice) *
            int256(shortPosition);
    }

    function getUserPosition(address account)
        public
        returns (
            uint256 margin,
            uint256 longPosition,
            uint256 longPrice,
            uint256 shortPosition,
            uint256 shortPrice
        )
    {
        Swapper storage swapper = swappers[account];
        margin = swapper.margin;
        longPosition = swapper.longPosition;
        longPrice = swapper.longPrice;
        shortPosition = swapper.shortPosition;
        shortPrice = swapper.shortPrice;
    }

    function getLatestPrice() public view returns (uint256) {
        (
            uint80 roundID,
            int256 price,
            uint256 startedAt,
            uint256 timeStamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        return uint256(price);
    }
}
