pragma solidity ^0.6.2;

import "./ERC20.sol";

contract ERC20TransferBurn is ERC20 {
    using SafeMath for uint256;

    constructor (string memory name, string memory symbol) ERC20(name, symbol) public {}

    // the amount of burn during every transfer, i.e. 100 = 1%, 50 = 2%, 40 = 2.5%
    uint256 private _burnDivisor = 100;

    function burnDivisor() public view virtual returns (uint256) {
        return _burnDivisor;
    }

    function _setBurnDivisor(uint256 burnDivisor) internal virtual {
        require(burnDivisor > 0, "_setBurnDivisor burnDivisor must be bigger than 0");
        _burnDivisor = burnDivisor;
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        // calculate burn amount
        uint256 burnAmount = amount.div(_burnDivisor);
        // burn burn amount
        burn(msg.sender, burnAmount);
        // transfer amount minus burn amount
        return super.transfer(recipient, amount.sub(burnAmount));
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        // calculate burn amount
        uint256 burnAmount = amount.div(_burnDivisor);
        // burn burn amount
        burn(sender, burnAmount);
        // transfer amount minus burn amount
        return super.transferFrom(sender, recipient, amount.sub(burnAmount));
    }

    // keep track of total supply burned (for fun only, serves no purpose)
    uint256 private _totalSupplyBurned;

    function totalSupplyBurned() public view virtual returns (uint256) {
        return _totalSupplyBurned;
    }

    function burn(address account, uint256 amount) private {
        _burn(account, amount);
        // keep track of total supply burned
        _totalSupplyBurned = _totalSupplyBurned.add(amount);
    }
}
