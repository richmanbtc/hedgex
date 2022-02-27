//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;
import "./interfaces/IIndexPrice.sol";
import "./Ownable.sol";

contract TripleIndexPrice is IIndexPrice, Ownable {
    //the decimal of the index price, for example 100000000 for all the usdx
    uint24 public constant divConst = 100000;
    uint24 public constant slideScale = 110000;
    uint8 public constant slideP = 5;
    uint8 public constant halfNumber = 25;
    uint16 public constant maxSlideRate = 2000;
    uint8 public constant feeDRate = 120;
    uint256 public constant override decimals = 10000;
    bytes32 public symbol;

    uint256 price;
    uint256 priceSlideRateUp;
    uint256 slideUpHeight;
    uint256 priceSlideRateDown;
    uint256 slideDownHeight;

    mapping(address => int8) public posters;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "0");
        _;
    }

    constructor(string memory _symbol, uint256 value) {
        symbol = keccak256(abi.encodePacked(_symbol));
        owner = msg.sender;
        price = value;
        posters[msg.sender] = 6;
    }

    function postPrice(uint256 value, uint256 deadline)
        external
        ensure(deadline)
    {
        require(posters[msg.sender] == 6, "1");
        require(value > 0, "2");

        //1. caculate the priceSlideRate in current block number
        (
            priceSlideRateUp,
            priceSlideRateDown,
            slideUpHeight,
            slideDownHeight
        ) = getCurrentPriceSlideRate();

        //2. caculate the slideRate in this tx
        uint256 deltaP = 0;
        if (value > price) deltaP = value - price;
        else deltaP = price - value;
        uint256 deltaPR = (deltaP * divConst) / price;

        if (deltaPR > feeDRate) {
            uint256 slideRate = ((deltaPR - feeDRate) * slideScale) / divConst;
            if (slideRate > maxSlideRate) {
                slideRate = maxSlideRate;
            }
            if (value > price) {
                if (slideRate > priceSlideRateUp) {
                    priceSlideRateUp = slideRate;
                    slideUpHeight = block.number;
                }
            } else {
                if (slideRate > priceSlideRateDown) {
                    priceSlideRateDown = slideRate;
                    slideDownHeight = block.number;
                }
            }
        }
        if ((value > price) && (priceSlideRateUp == maxSlideRate)) {
            price += (maxSlideRate * price) / divConst;
        } else if ((value < price) && (priceSlideRateDown == maxSlideRate)) {
            price -= (maxSlideRate * price) / divConst;
        } else {
            price = value;
        }
    }

    function getCurrentPriceSlideRate()
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        uint256 slideRateUp = priceSlideRateUp;
        uint256 slideRateDown = priceSlideRateDown;
        uint256 heightUp = slideUpHeight;
        while (slideRateUp > slideP) {
            if ((heightUp + halfNumber) > block.number) {
                break;
            }
            heightUp += halfNumber;
            slideRateUp /= 2;
        }
        uint256 heightDown = slideDownHeight;
        while (slideRateDown > slideP) {
            if ((heightDown + halfNumber) > block.number) {
                break;
            }
            heightDown += halfNumber;
            slideRateDown /= 2;
        }
        if (slideRateUp < slideP) {
            slideRateUp = slideP;
        }
        if (slideRateDown < slideP) {
            slideRateDown = slideP;
        }
        return (slideRateUp, slideRateDown, heightUp, heightDown);
    }

    function indexPrice()
        external
        view
        override
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        (
            uint256 slideRateUp,
            uint256 slideRateDown,
            ,

        ) = getCurrentPriceSlideRate();
        uint256 slideUpPrice = (price * slideRateUp) / divConst;
        uint256 slideDownPrice = (price * slideRateDown) / divConst;
        return (price, slideUpPrice, slideDownPrice, decimals);
    }

    function setPosters(address poster, int8 value) external {
        require(msg.sender == owner, "1");
        posters[poster] = value;
    }
}
