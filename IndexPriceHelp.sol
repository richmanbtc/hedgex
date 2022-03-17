//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;
import "./interfaces/IHedgex.sol";

contract HedgexIndexHelper {
    constructor() {}

    function indexPrice(address[] memory addresses)
        external
        view
        returns (uint256[] memory)
    {
        uint256[] memory prices = new uint256[](addresses.length);
        for (uint256 index = 0; index < addresses.length; index++) {
            IHedgexSingle hedgex = IHedgexSingle(addresses[index]);
            (uint256 price, , ) = hedgex.getLatestPrice();
            prices[index] = price;
        }
        return prices;
    }
}
