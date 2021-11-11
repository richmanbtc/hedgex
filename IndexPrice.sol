//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/AggregatorV3Interface.sol";

contract IndexPrice {
    address public immutable wethUsdt;
    address public immutable wethUsdc;
    address public immutable linkEthUsd;

    constructor(
        address add1,
        address add2,
        address add3
    ) {
        wethUsdt = add1;
        wethUsdc = add2;
        linkEthUsd = add3;
    }

    function getLatestPrice() external view returns (uint256) {
        (, int256 price, , , ) = AggregatorV3Interface(linkEthUsd)
            .latestRoundData();

        (uint256 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(wethUsdc).slot0();
        return uint256(price) + sqrtPriceX96;
    }
}
