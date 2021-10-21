//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.7;

import "./Single.sol";

contract HedgexFactory {
    address public feeTo;
    address public feeToSetter;
    address internal newFeeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    mapping(address => mapping(address => string)) public getPairName;
    address[] public allPairs;

    event PairCreated(
        address indexed token0,
        address indexed priceFeeder,
        address pair,
        uint256
    );

    constructor() {
        feeToSetter = msg.sender;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(
        address token0,
        address priceFeed,
        uint256 feedPriceDecimal,
        uint256 minStartPool,
        uint8 leverage,
        int8 amountDecimal,
        string memory name
    ) external returns (address pair) {
        require(token0 != address(0), "hedgex: ZERO_ADDRESS");
        (, int256 price, , , ) = AggregatorV3Interface(priceFeed)
            .latestRoundData();
        require(price > 0, "hedgex: INVALID_PREICE_FEEDinvalid");
        require(
            getPair[token0][priceFeed] == address(0),
            "hedgex: PAIR_EXISTS"
        );
        bytes memory bytecode = type(HedgexSingle).creationCode;
        bytes32 salt = keccak256(
            abi.encodePacked(
                token0,
                priceFeed,
                feedPriceDecimal,
                minStartPool,
                leverage,
                amountDecimal
            )
        );
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        HedgexSingle(pair).initialize(
            token0,
            priceFeed,
            feedPriceDecimal,
            minStartPool,
            leverage,
            amountDecimal
        );
        getPair[token0][priceFeed] = pair;
        getPairName[token0][priceFeed] = name;
        allPairs.push(pair);
        emit PairCreated(token0, priceFeed, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "hedgex: FORBIDDEN");
        feeTo = _feeTo;
    }

    function transferFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "hedgex: FORBIDDEN");
        newFeeToSetter = _feeToSetter;
    }

    function acceptFeeToSetter() external {
        require(msg.sender == newFeeToSetter, "hedgex: FORBIDDEN");
        feeToSetter = newFeeToSetter;
        newFeeToSetter = address(0);
    }
}
