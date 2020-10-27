// ERC20Elastic is duplicated in ERC20Elastic.sol and ERC20ElasticTransferBurn.sol
// because I don't know how to not duplicate it

pragma solidity ^0.6.0;

import "./ERC20.sol";

contract ERC20Elastic is ERC20 {
    using SafeMath for uint256;

    constructor (string memory name, string memory symbol) ERC20(name, symbol) public {}

    uint256 private _elasticMultiplier = 100;

    function elasticMultiplier() public view virtual returns (uint256) {
        return _elasticMultiplier;
    }

    function _setElasticMultiplier(uint256 elasticMultiplier) internal virtual {
        require(elasticMultiplier > 0, "_setElasticMultiplier elasticMultiplier must be bigger than 0");
        _elasticMultiplier = elasticMultiplier;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return super.balanceOf(account).mul(_elasticMultiplier);
    }

    // don't override totalSupply to cause more madness and confusion
    function totalSupplyElastic() public view virtual returns (uint256) {
        return super.totalSupply().mul(_elasticMultiplier);
    }

    function balanceOfRaw(address account) public view virtual returns (uint256) {
        return super.balanceOf(account);
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        return super.transfer(recipient, amount.div(_elasticMultiplier));
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        return super.transferFrom(sender, recipient, amount.div(_elasticMultiplier));
    }
}

