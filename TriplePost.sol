//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;
import "./interfaces/IIndexPrice.sol";
import "./Ownable.sol";

contract TripleIndexPrice is IIndexPrice, Ownable {
    //the decimal of the index price, for example 100000000 for all the usdx
    uint16 public constant divConst = 10000;
    uint16 public constant slideScale = 11000;
    uint8 public constant halfNumber = 1;
    uint8 public constant maxSlideRate = 200;
    uint8 public immutable feeDRate;
    uint256 public immutable override decimals;
    uint256 public updateAt;
    bytes32 public symbol;

    uint256 price;
    uint256 priceSlideRate;
    uint256 slideHeight;
    int8 slideDirection;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "0");
        _;
    }

    constructor(
        string memory _symbol,
        uint256 _priceDecimal,
        uint8 _feeDRate,
        uint256 value
    ) {
        symbol = keccak256(abi.encodePacked(_symbol));
        decimals = _priceDecimal;
        owner = msg.sender;
        feeDRate = _feeDRate;
        price = value;
        slideDirection = 1;
    }

    function postPrice(uint256 value, uint256 deadline)
        external
        ensure(deadline)
    {
        require(msg.sender == owner, "1");
        require(value > 0, "2");

        //1. caculate the priceSlideRate in current block number
        (priceSlideRate, slideHeight) = getCurrentPriceSlideRate();

        //2. caculate the slideRate in this tx
        uint256 deltaP = 0;
        if (value > price) deltaP = value - price;
        else deltaP = price - deltaP;
        uint256 deltaPR = (deltaP * divConst) / price;

        if (deltaPR > feeDRate) {
            uint256 slideRate = ((deltaPR - feeDRate) * slideScale) / divConst;
            if (slideRate > maxSlideRate) {
                slideRate = maxSlideRate;
            }
            if (slideRate > priceSlideRate) {
                priceSlideRate = slideRate;
                slideHeight = block.number;
                if (value > price) {
                    slideDirection = 1;
                } else {
                    slideDirection = -1;
                }
            }
        }
        if (priceSlideRate == maxSlideRate) {
            deltaP = (maxSlideRate * price) / divConst;
            if (value > price) {
                price += deltaP;
            } else {
                price -= deltaP;
            }
        } else {
            price = value;
        }
        updateAt = block.timestamp;
    }

    function getCurrentPriceSlideRate() public view returns (uint256, uint256) {
        uint256 slideRate = priceSlideRate;
        uint256 height = slideHeight;
        while (slideRate > feeDRate) {
            if ((height + halfNumber) > block.number) {
                break;
            }
            height += halfNumber;
            slideRate /= 2;
        }
        if (slideRate <= feeDRate) {
            slideRate = 0;
        }
        return (slideRate, height);
    }

    function indexPrice()
        external
        view
        override
        returns (
            uint256,
            uint256,
            int256
        )
    {
        (uint256 slideRate, ) = getCurrentPriceSlideRate();
        int256 slidePrice = slideDirection *
            (int256((price * slideRate) / divConst));
        return (price, decimals, slidePrice);
    }
}
