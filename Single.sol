//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.7.2;
import "./interfaces/AggregatorV3Interface.sol";
import "./interfaces/IERC20.sol"
import "./libraries/TransferHelper.sol"

/// @title Single pair hedge pool contract
contract HedgexSingle is HedgexERC20{
    //define a struct for the hedge swapper
    struct Swapper {
        int256 margin; // the margin of the user
        int256 longPosition;
        uint256 longPrice;
        int256 shortPosition;
        uint256 shortPrice;
    }

    //the min pool's amount
    uint256 immutable minPool;

    //the max pool's amount
    uint256 maxPool;

    //
    uint8 immutable leverage;

    // it is mean x / 10000
    constant dailyInterestRateBase = 10;

    int8 feeOn;

    uint256 sumFee;

    // it is mean x / 10000, for example feeRate = 5, is mean 0.0005
    uint feeRate;

    //the current total amount of token0 for pool
    uint256 totalPool;

    //token0 is the coin of margin
    address public token0;

    //the position of the total pool, the direction is negative to the user's total position
    uint256 public longPosition;
    uint256 public shortPosition;

    //the price of the positionPool
    uint256 public longPrice;
    uint256 public shortPrice

    //all the swappers
    mapping(address => Swapper) public swappers;

    //get the price feed address
    AggregatorV3Interface immutable private priceFeed;

    event Mint(address indexed sender, uint256 amount);
    event Burn(address indexed sender, uint256 amount);
    event Recharge(address indexed sender, uint256 amount);
    event Withdraw(address indexed sender, uint256 amount);


    constructor(address _token0, address _feedPrice, uint256 _minPool, uint8 _leverage) public {
        priceFeed = AggregatorV3Interface(_feedPrice);
        token0 = _token0;
        minPool = _minPool;
        leverage = _leverage
    }

    //add liquidity of token0 to the pool
    function addLiquidityToPool(
        uint256 amount, // the amount of token0 to add the pool
        address to, // the address which the lp token to send
        uint deadline // the deadline timestamp
        ) ensure(deadline)
        external {
        //transfer token to this contract, it need user to approve this contract to tranferfrom the token
        TransferHelper.safeTransferFrom(token0, msg.sender, address(this), amount);
        int256 net = getPoolNet();
        require(net > 0, "net need be position"); // ???
        uint256 liquidity = totalSupply * amount / net
        totalPool += amount
        _mint(to, liquidity)
        emit Mint(msg.sender, liquidity)
    }

    //remove liquidity of token0 from the pool
    function removeLiquidityFromPool(
        uint liquidity,
        address to,
        uint deadline
    )
    external{
        //send liquidity to this contract
        TransferHelper.safeTransfer(address(this), address(this), liquidity);
        int256 net = getPoolNet();
        require(net > 0, "net need be position"); // ???
        uint256 amount = net * liquidity / totalSupply
        _burn(address(this), liquidity);
        TransferHelper.safeTransferFrom(token0, address(this), to, amount);
        emit Burn(msg.sender, liquidity)
    }

    function rechargeMargin(
        uint256 amount, // the amount of token0 to add the pool
        uint deadline // the deadline timestamp
        ) ensure(deadline)
        external {
        //transfer token to this contract, it need user to approve this contract to tranferfrom the token
        TransferHelper.safeTransferFrom(token0, msg.sender, address(this), amount);
        swappers[msg.sender].margin += amount
        emit Recharge(msg.sender, amount)
    }

    function withdrawMargin(
        uint amount,
        uint deadline
        ) ensure(deadline)
        external {
        Swapper swaper = swapers[msg.sender];

        //cacculate the net of swaper
        int256 price = getLatestPrice();

        uint useMargin = (swaper.longPosition + swaper.shortPrice) * price / leverage;

        uint net = swaper.margin + swaper.longPosition * (price - swaper.longPrice) + swaper.shortPosition * (swaper.shortPrice - price)

        uint canWithdrawMargin = net - useMargin;
        uint maxAmount = amount;
        if(amount > canWithdrawMargin){
            maxAmount = canWithdrawMargin;
        }

        TransferHelper.safeTransfer(token0, msg.sender, maxAmount);        
        emit Withdraw(msg.sender, maxAmount)
    }

    function Open(
        int8 direction,
        uint256 price,
        uint256 amount
    ){
        Swapper swaper = swapers[msg.sender];
        int256 price = getLatestPrice();
        uint8 _leverage = leverage;
        uint useMargin = (swaper.longPosition + swaper.shortPosition) * price / _leverage;

        int net = swaper.margin + swaper.longPosition * (price - swaper.longPrice) + swaper.shortPosition * (swaper.shortPrice - price)

        int canUseMargin = net - useMargin;

        uint canAmount = canUseMargin * _leverage / price;

        if(canAmount < amount){
            amount = canAmount;
        }

        if(direction > 0){
            swapers[msg.sender].longPosition = swaper.longPosition + amount;
            swapers[msg.sender].longPrice = (swaper.longPosition * swaper.longPrice + amount * price) / (swaper.longPosition + amount);
            
            int256 _shortPosition = shortPosition;
            shortPosition = _shortPosition + amount;
            shortPrice = (_shortPosition * shortPrice + amount * price) / (_shortPosition + amount);
        }else if(direction < 0){
            swapers[msg.sender].shortPosition = swaper.shortPosition + amount;
            swapers[msg.sender].shortPrice = (swaper.shortPosition * swaper.shortPrice + amount * price) / (swaper.shortPosition + amount);

            int256 _longPosition = longPosition;
            longPosition = _longPosition + amount;
            longPrice = (_longPosition * longPrice + amount * price) / (_longPosition + amount);
        }

        uint fee = amount * price * feeRate / 10000;
        swapers[msg.sender].margin = swaper.margin - fee;

        if(feeOn){
            sumFee += fee / 6;
            totalPool += fee - fee/6;
        }else{
            totalPool += fee;
        }
    }

    function Close(
        int8 direction,
        uint256 price,
        uint256 amount
    ){
        int256 price = getLatestPrice();
        Swapper swaper = swapers[msg.sender];
        uint fee = amount * price * feeRate / 10000;
        uint _poolFee = 0;
        if(feeOn){
            sumFee += fee / 6;
            _poolFee = fee - fee/6;
        }else{
            _poolFee = fee;
        }
        if(direction > 0){
            require(amount <= swaper.longPosition, "long position is not enough");
            profit = amount * (price - swaper.longPrice);
            swapers[msg.sender].longPosition = swaper.longPosition - amount;
            swapers[msg.sender].margin = swaper.margin + profit - fee;

            int256 _shortPosition = shortPosition;
            shortPosition = _shortPosition - amount;
            totalPool = totalPool - profit + _poolFee;
        }else(direction < 0){
            require(amount <= swaper.shortPosition, "short position is not enough");
            profit = amount * (swaper.shortPrice - price);
            swapers[msg.sender].shortPosition = swaper.shortPosition - amount;
            swapers[msg.sender].margin = swaper.margin + profit - fee;

            int256 _longPosition = longPosition;
            longPosition = _longPosition - amount;
            totalPool = totalPool - proft + _poolFee;
        }
    }

    function explosive(
        address account,
        address to
    ){
        Swapper swaper = swapers[account];
        int256 price = getLatestPrice();

        uint keepMargin = (swaper.longPosition + swaper.shortPosition) * price / 30;
        int net = swaper.margin + swaper.longPosition * (price - swaper.longPrice) + swaper.shortPosition * (swaper.shortPrice - price)
        require(net <= keepMargin, "The price is not required");

        if(net > 0){ // send the left token0 to the to for regard
            TransferHelper.safeTransfer(token0, to, net);
        }else{
            totalToken += net
        }

        swapers[account].margin = 0;
        swapers[account].longPosition = 0;
        swapers[account].shortPosition = 0;

        if(swaper.longPosition > 0){
            shortPosition -= swaper.shortPosition;
        }
        if(swaper.shortPosition > 0){
            longPosition -= swaper.longPosition;
        }
    }

    function detectSlide(
        address account,
        address to
    ){
        int256 price = getLatestPrice();
        Swapper storage swaper = swapers[account];
        require(swaper.longPosition != swaper.shortPosition, "need long and short not equal");

        uint256 _shortPosition = shortPosition;
        uint256 _longPosition = longPosition;
        uint256 interest = 0;
        if(swaper.longPosition > swaper.shortPosition){
            require(_shortPosition > _longPosition, "have no interest");            
            interest = price * swaper.longPosition * dailyInterestRateBase * (_shortPosition - _longPosition) / _shortPosition;
        }else{
            require(_longPosition > _shortPosition, "have no interest");
            interest = price * swaper.shortPosition * dailyInterestRateBase * (_longPosition - _shortPosition) / _longPosition;
        }
        uint256 reward = interest / 10;
        swaper.margin -= interest;
        totalPool += interest - reward;
        TransferHelper.safeTransfer(token0, to, reward);
    }

    //get the pool's current net
    function getPoolNet() public returns (int256){
        int256 price = getLatestPrice();
        return totalPool + (longPrice - price) * longPosition + (price - shortPrice) * shortPosition;
    }

    function getLatestPrice() public view returns (int256) {
        (
            uint80 roundID,
            int256 price,
            uint256 startedAt,
            uint256 timeStamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        return price;
    }
}
