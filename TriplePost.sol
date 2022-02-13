//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;
import "./interfaces/IIndexPrice.sol";
import "./Ownable.sol";

contract TripleIndexPrice is IIndexPrice, Ownable {
    //the decimal of the index price, for example 100000000 for all the usdx
    uint256 public immutable override decimals;
    uint256 public updateAt;
    bytes32 public symbol;
    uint256 price;

    constructor(string memory _symbol, uint256 _priceDecimal) {
        symbol = keccak256(abi.encodePacked(_symbol));
        decimals = _priceDecimal;
    }

    function postPrice(bytes32 _symbol, uint256 value) external {
        require(msg.sender == owner);
        require(symbol == _symbol);
        require(value > 0);
        price = value;
        updateAt = block.timestamp;
    }

    function indexPrice()
        external
        view
        override
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        return (price, decimals, updateAt);
    }
}
