pragma solidity ^0.6.2;

import "./ERC20ElasticTransferBurn.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BloodyToken is ERC20ElasticTransferBurn("BloodyToken", "BLOODY"), Ownable {
    using SafeMath for uint256;

    // store how many transfers have occurred every hour
    // to calculate the burn divisor
    uint256 public transferVolumeNowBucket;
    uint256 public transferVolume1HourAgoBucket;

    // store the now timestamp to know when it has expired
    uint256 public transferVolumeNowBucketTimestamp;

    constructor() public {
        // set to arbitrary initial values
        _setBurnDivisor(100);
        _setElasticMultiplier(10);

        // freeze transfers for 5 minutes after rebase
        // to mitigate users transferring wrong amounts
        transferAfterRebaseFreezeTime = 5 minutes;

        transferVolumeNowBucketTimestamp = getTransferVolumeNowBucketTimestamp();
    }

    function getTransferVolumeNowBucketTimestamp() public view returns (uint256) {
        // 3600 seconds per hour
        // round the timestamp bucket every hour
        return block.timestamp - (block.timestamp % 3600);
    }

    event Rebase(
        uint256 indexed transferVolumeNowBucketTimestamp, uint256 burnDivisor, uint256 elasticMultiplier, 
        uint256 transferVolume1HourAgoBucket, uint256 transferVolume2HoursAgoBucket
    );

    uint256 public lastRebaseTimestamp;
    uint256 public transferAfterRebaseFreezeTime;

    function rebase() public {
        // time is still in current bucket, does not need updating
        require(requiresRebase() == true, "someone else called rebase already");

        // update volume buckets
        // shift buckets 1 spot
        uint256 transferVolume2HoursAgoBucket = transferVolume1HourAgoBucket;
        transferVolume1HourAgoBucket = transferVolumeNowBucket;
        transferVolumeNowBucket = 0;

        // store new timestamp
        transferVolumeNowBucketTimestamp = getTransferVolumeNowBucketTimestamp();

        // mint half the burn to the uniswap pairs
        // make sure to sync the uniswap pairs after
        uint256 uniswapPairReward = transferVolume1HourAgoBucket.div(burnDivisor()).div(2);
        mintToUniswapPairs(uniswapPairReward);

        // rebase supply and burn rate
        uint256 newBurnDivisor = calculateBurnDivisor(burnDivisor(), transferVolume1HourAgoBucket, transferVolume2HoursAgoBucket);
        // arbitrarily set elastic modifier to 10x the burn rate (10 * 100 / burnDivisor)
        // if bloody circulates, spill rate increases, but clotting decreases
        // if volume increases, burn rate increases (burn divisor decreases), supply increases
        uint256 newElasticMultiplier = uint256(1000).div(newBurnDivisor);
        _setBurnDivisor(newBurnDivisor);
        _setElasticMultiplier(newElasticMultiplier);
        emit Rebase(transferVolumeNowBucketTimestamp, newBurnDivisor, newElasticMultiplier, transferVolume1HourAgoBucket, transferVolume2HoursAgoBucket);

        // if uniswap pairs are not synced loss of
        // funds will occur after rebase or reward minting
        syncUniswapPairs();

        // set to false until next rebase
        setRequiresRebase(false);
        lastRebaseTimestamp = block.timestamp;
    }

    uint256 public constant minBurnPercent = 1;
    uint256 public constant maxBurnPercent = 12;
    // they are inversely correlated
    uint256 public constant minBurnDivisor = 100 / maxBurnPercent;
    uint256 public constant maxBurnDivisor = 100 / minBurnPercent;

    // if bloody circulates, spill rate increases, but clotting decreases
    // if volume decreases, burn rate decreases (burn divisor increases), supply decreases
    // if supply decreases, price goes up, which stimulates more volume, which in turn
    // increases burn
    // if volume increases, burn rate increases (burn divisor decreases), supply increases
    function calculateBurnDivisor(uint256 _previousBurnDivisor, uint256 _transferVolume1HourAgoBucket, uint256 _transferVolume2HoursAgoBucket) public view returns (uint256) {
        // convert burn divisor to burn percent using division precision
        int256 divisionPrecision = 10000;
        int256 preciseMinBurnPercent = int256(minBurnPercent) * divisionPrecision;
        int256 preciseMaxBurnPercent = int256(maxBurnPercent) * divisionPrecision;
        // don't divide by 0
        if (_previousBurnDivisor == 0) {
            return minBurnDivisor;
        }
        int256 precisePreviousBurnPercent = (100 * divisionPrecision) / int256(_previousBurnDivisor);

        // no update needed
        if (_transferVolume1HourAgoBucket == _transferVolume2HoursAgoBucket) {
            // never return burn divisor above or below max
            if (precisePreviousBurnPercent < preciseMinBurnPercent) {
                return maxBurnDivisor;
            }
            else if (precisePreviousBurnPercent > preciseMaxBurnPercent) {
                return minBurnDivisor;
            }
            else {
                return _previousBurnDivisor;
            }
        }

        bool volumeHasIncreased = _transferVolume1HourAgoBucket > _transferVolume2HoursAgoBucket;

        // check for min / max already reached
        if (volumeHasIncreased) {
            // volume has increased but 
            // burn percent is already max (burn divisor is already min)
            if (precisePreviousBurnPercent >= preciseMaxBurnPercent) {
                return minBurnDivisor;
            }
        }
        // volume has decreased
        else {
            // volume has decreased but 
            // burn percent is already min (burn divisor is already max)
            if (precisePreviousBurnPercent <= preciseMinBurnPercent) {
                return maxBurnDivisor;
            }
        }

        // find the transfer volume difference ratio between the 2 hour buckets
        int256 transferVolumeRatio;
        if (_transferVolume1HourAgoBucket == 0) {
            transferVolumeRatio = -int256(_transferVolume2HoursAgoBucket + 1);
        }
        else if (_transferVolume2HoursAgoBucket == 0) {
            transferVolumeRatio = int256(_transferVolume1HourAgoBucket + 1);
        }
        else if (volumeHasIncreased) {
            transferVolumeRatio = int256(_transferVolume1HourAgoBucket / _transferVolume2HoursAgoBucket);
        }
        else {
            transferVolumeRatio = -int256(_transferVolume2HoursAgoBucket / _transferVolume1HourAgoBucket);
        }

        // find the burn percent modifier and the new burn percent
        // round division to 10000
        int256 preciseNewBurnPercent = calculateBurnPercentFromTransferVolumeRatio(
            precisePreviousBurnPercent,
            transferVolumeRatio * divisionPrecision, 
            preciseMinBurnPercent, 
            preciseMaxBurnPercent
        );

        // convert the burn percent back to burn divisor, without forgetting division precision
        return uint256((100 * divisionPrecision) / preciseNewBurnPercent);
    }

    function calculateBurnPercentFromTransferVolumeRatio(int256 _previousBurnPercent, int256 _transferVolumeRatio, int256 _minBurnPercent, int256 _maxBurnPercent) public pure returns (int256) {
        // this is a pure function, don't use globals min and max
        // because might use division precision

        // previous burn percent should never be bigger or smaller than max or min
        // but if the exception occurs it messes up the curve
        if (_previousBurnPercent < _minBurnPercent) {
            _previousBurnPercent = _minBurnPercent;
        }
        else if (_previousBurnPercent > _maxBurnPercent) {
            _previousBurnPercent = _maxBurnPercent;
        }

        // attempt to find burn divisor curve
        int256 burnPercentModifier = _transferVolumeRatio;
        int8 maxAttempt = 5;
        while (true) {
            int256 newBurnPercent = _previousBurnPercent + burnPercentModifier;
            // found burn divisor curve
            if (newBurnPercent < _maxBurnPercent && newBurnPercent > _minBurnPercent) {
                return _previousBurnPercent + burnPercentModifier;
            }

            // curve formula brings too little change to burn divisor, not worth it
            if (maxAttempt-- == 0) {
                // instead of returning the value very close to the min or max
                // return min or max instead to avoid wasting gas
                if (_transferVolumeRatio > 0) {
                    // if _transferVolumeRatio is positive, burn should increase
                    return _maxBurnPercent;
                }
                else {
                    // bigger than max would give min
                    return _minBurnPercent;
                }
            }

            // divide by 2 until burnPercent + burnPercentModifier
            // fit between min and max to find the perfect curve
            burnPercentModifier = burnPercentModifier / 2;
        }
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        // if time for rebase, freeze all transfers until someone calls rebase
        require(requiresRebase() == false, "transfers are frozen until someone calls rebase");
        require(transfersAreFrozenAfterRebase() == false, "transfers are frozen for a few minutes after rebase");
        super.transfer(recipient, amount);
        updateTransferVolume(amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        // if time for rebase, freeze all transfers until someone calls rebase
        require(requiresRebase() == false, "transfers are frozen until someone calls rebase");
        require(transfersAreFrozenAfterRebase() == false, "transfers are frozen for a few minutes after rebase");
        super.transferFrom(sender, recipient, amount);
        updateTransferVolume(amount);
        return true;
    }

    function updateTransferVolume(uint256 volume) internal virtual {
        // keep track of transfer volume on each transfer
        // store the volume without elastic multiplier to know the real volume
        transferVolumeNowBucket = transferVolumeNowBucket.add(volume.div(elasticMultiplier()));

        // if 1 hour has passed, requires new rebase
        if (transferVolumeNowBucketTimestamp != getTransferVolumeNowBucketTimestamp()) {
            setRequiresRebase(true);
        }
    }

    function transfersAreFrozenAfterRebase() public view returns (bool) {
        // use < and not <= to always stop transfers that occur on the same block as a rebase
        // even if transferAfterRebaseFreezeTime is set to 0
        if (lastRebaseTimestamp + transferAfterRebaseFreezeTime < block.timestamp) {
            return false;
        }
        return true;
    }

    // if should rebase, freeze all transfers until someone calls rebase
    bool private _requiresRebase = false;
    // only require rebase on the next block
    uint256 private lastSetRequiresRebaseTimestamp;

    function requiresRebase() public view returns (bool) {
        if (_requiresRebase) {
            if (lastSetRequiresRebaseTimestamp < block.timestamp) {
                return true;
            }
        }
        return false;
    }

    function setRequiresRebase (bool value) internal {
        _requiresRebase = value;
        lastSetRequiresRebaseTimestamp = block.timestamp;
    }

    // mint half the burn to the uniswap pair to incentivize liquidity
    // swapping or providing liquidity on any other pairs will cause
    // loss of funds after every rebase
    address public bloodyEthUniswapPair;
    address public bloodyNiceUniswapPair;
    address public bloodyRotUniswapPair;

    // called by owner after contract is deployed to set
    // the uniswap pair which receives half the burn to incentivize liquidity
    // then contract ownership is transfered to
    // address 0x0000000000000000000000000000000000000000 and can never be called again
    function setUniswapPairs(address _bloodyEthUniswapPair, address _bloodyNiceUniswapPair, address _bloodyRotUniswapPair) public virtual onlyOwner {
        bloodyEthUniswapPair = _bloodyEthUniswapPair;
        bloodyNiceUniswapPair = _bloodyNiceUniswapPair;
        bloodyRotUniswapPair = _bloodyRotUniswapPair;
    }

    // mint half the burn to the uniswap pairs
    // make sure to sync the uniswap pairs after
    // reward is half of the burn split into 3 pairs
    function mintToUniswapPairs(uint256 uniswapPairRewardAmount) internal {
        if (uniswapPairRewardAmount == 0) {
            return;
        }
        // reward is half of the burn split into 3 pairs
        uint256 amountPerPair = uniswapPairRewardAmount.div(3);
        if (uniswapPairRewardAmount == 0) {
            return;
        }
        if (bloodyEthUniswapPair != address(0)) {
            _mint(bloodyEthUniswapPair, amountPerPair);
        }
        if (bloodyNiceUniswapPair != address(0)) {
            _mint(bloodyNiceUniswapPair, amountPerPair);
        }
        if (bloodyRotUniswapPair != address(0)) {
            _mint(bloodyRotUniswapPair, amountPerPair);
        }
    }

    // if uniswap pairs are not synced loss of
    // funds will occur after rebase or reward minting
    function syncUniswapPairs() internal {
        if (bloodyEthUniswapPair != address(0)) {
            IUniswapV2Pair(bloodyEthUniswapPair).sync();
        }
        if (bloodyNiceUniswapPair != address(0)) {
            IUniswapV2Pair(bloodyNiceUniswapPair).sync();
        }
        if (bloodyRotUniswapPair != address(0)) {
            IUniswapV2Pair(bloodyRotUniswapPair).sync();
        }
    }

    // called by owner after contract is deployed to airdrop
    // tokens to inital holders, then contract ownership is transfered to
    // address 0x0000000000000000000000000000000000000000 and can never be called again
    function airdrop(address[] memory recipients, uint256[] memory amounts) public onlyOwner {
        for (uint i = 0; i < recipients.length; i++) {
            _mint(recipients[i], amounts[i]);
        }
    }

    // util external function for website
    function totalSupplyBurnedElastic() external view returns (uint256) {
        return totalSupplyBurned().mul(elasticMultiplier());
    }

    // util external function for website
    // half the burn is minted to the uniswap pools
    // might not be accurate if uniswap pools aren't set yet
    function totalSupplyBurnedMinusRewards() public view returns (uint256) {
        return totalSupplyBurned().div(2);
    }

    // util external function for website
    function timeUntilNextRebase() external view returns (uint256) {
        uint256 rebaseTime = transferVolumeNowBucketTimestamp + 3600;
        if (rebaseTime <= block.timestamp) {
            return 0;
        }
        return rebaseTime - block.timestamp;
    }

    // util external function for website
    function nextRebaseTimestamp() external view returns (uint256) {
        return transferVolumeNowBucketTimestamp + 3600;
    }

    // util external function for website
    function transfersAreFrozen() external view returns (bool) {
        if (transfersAreFrozenAfterRebase() || requiresRebase()) {
            return true;
        }
        return false;
    }

    // util external function for website
    function transfersAreFrozenRequiresRebase() external view returns (bool) {
        return requiresRebase();
    }

    // util external function for website
    function timeUntilNextTransferAfterRebaseUnfreeze() external view virtual returns (uint256) {
        uint256 unfreezeTime = lastRebaseTimestamp + transferAfterRebaseFreezeTime;
        if (unfreezeTime <= block.timestamp) {
            return 0;
        }
        return unfreezeTime - block.timestamp;
    }

    // util external function for website
    function nextTransferAfterRebaseUnfreezeTimestamp() external view virtual returns (uint256) {
        return lastRebaseTimestamp + transferAfterRebaseFreezeTime;
    }

    // util external function for website
    function balanceInUniswapPair(address user, address uniswapPair) public view returns (uint256) {
        if (uniswapPair == address(0)) {
            return 0;
        }
        uint256 pairBloodyBalance = balanceOf(uniswapPair);
        if (pairBloodyBalance == 0) {
            return 0;
        }
        uint256 userLpBalance = IUniswapV2Pair(uniswapPair).balanceOf(user);
        if (userLpBalance == 0) {
            return 0;
        }
        uint256 lpTotalSupply = IUniswapV2Pair(uniswapPair).totalSupply();
        uint256 divisionPrecision = 1e12;
        uint256 userLpTotalOwnershipRatio = userLpBalance.mul(divisionPrecision).div(lpTotalSupply);
        return pairBloodyBalance.mul(userLpTotalOwnershipRatio).div(divisionPrecision);
    }

    // util external function for website
    function balanceInUniswapPairs(address user) public view returns (uint256) {
        return balanceInUniswapPair(user, bloodyEthUniswapPair)
            .add(balanceInUniswapPair(user, bloodyNiceUniswapPair))
            .add(balanceInUniswapPair(user, bloodyRotUniswapPair));
    }

    // util external function for website
    function balanceIncludingUniswapPairs(address user) external view returns (uint256) {
        return balanceOf(user).add(balanceInUniswapPairs(user));
    }
}

interface IUniswapV2Pair {
    function sync() external;
    function balanceOf(address owner) external view returns (uint);
    function totalSupply() external view returns (uint);
}
