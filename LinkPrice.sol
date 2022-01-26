//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;
import "./interfaces/IIndexPrice.sol";
import "./interfaces/AggregatorV3Interface.sol";

contract LinkIndexPrice is IIndexPrice {
    //contract address which provide the index price feed oracle, it is show on chainlink
    AggregatorV3Interface public immutable feedPrice;

    //the decimal of the index price, for example 100000000 for all the usdx
    uint256 public immutable decimals;

    constructor(address _feedPrice, uint256 _feedPriceDecimal) {
        feedPrice = AggregatorV3Interface(_feedPrice);
        decimals = _feedPriceDecimal;
    }

    function indexPrice()
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        (, int256 price, , , ) = feedPrice.latestRoundData();
        if (price <= 0) {
            price = 0;
        }
        return (uint256(price), decimals, block.timestamp);
    }
}
