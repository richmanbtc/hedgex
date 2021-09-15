//SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.7;
import "./interfaces/IERC20.sol";

contract TokenERC20 is IERC20 {
    /*********Token的属性说明************/
    string public override name = "USDT rinkeby";
    string public override symbol = "USDT";
    uint8 public override decimals = 6; //
    uint256 public override totalSupply; // 发行量

    // 建立映射 地址对应了 uint' 便是他的余额
    mapping(address => uint256) public override balanceOf;
    // 地址对应余额
    mapping(address => mapping(address => uint256)) public override allowance;

    // 这里是构造函数, 实例创建时候执行
    constructor() {
        totalSupply = 10000000000 * 10**uint256(decimals); // 这里确定了总发行量
        balanceOf[msg.sender] = totalSupply; // 这里就比较重要, 这里相当于实现了, 把token 全部给合约的Creator
    }

    function _approve(
        address owner,
        address spender,
        uint256 value
    ) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(
        address from,
        address to,
        uint256 value
    ) private {
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function approve(address spender, uint256 value)
        external
        override
        returns (bool)
    {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value)
        external
        override
        returns (bool)
    {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external override returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= value;
        }
        _transfer(from, to, value);
        return true;
    }
}
