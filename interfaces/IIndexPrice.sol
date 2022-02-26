//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;

interface IIndexPrice {
    function indexPrice()
        external
        view
        returns (
            uint256 price,
            uint256 slideUpPrice,
            uint256 SlideDownPrice,
            uint256 decimal
        );

    function decimals() external returns (uint256);
}
