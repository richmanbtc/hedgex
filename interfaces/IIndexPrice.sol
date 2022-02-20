//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;

interface IIndexPrice {
    function indexPrice()
        external
        view
        returns (
            uint256 price,
            uint256 decimal,
            int256 slidePrice
        );

    function decimals() external returns (uint256);
}
