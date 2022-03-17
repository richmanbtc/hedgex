//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;

interface IHedgexSingle {
    function getLatestPrice()
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        );
}
