// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHealthCheck, ERC20} from "@periphery/HealthCheck/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBalancerVault, IERC20} from "./interfaces/Balancer/IBalancerVault.sol";
import {IBalancerPool} from "./interfaces/Balancer/IBalancerPool.sol";
import {IAsset} from "./interfaces/Balancer/IAsset.sol";
import {IConvexDeposit} from "./interfaces/Convex/IConvexDeposit.sol";
import {IConvexRewards} from "./interfaces/Convex/IConvexRewards.sol";

interface IRewardPoolDepositWrapper {
    function depositSingle(
        address _rewardPoolAddress,
        ERC20 _inputToken,
        uint256 _inputAmount,
        bytes32 _balancerPoolId,
        IBalancerVault.JoinPoolRequest memory _request
    ) external;
}


// TODO:
//  1. Non-manipulatable getRate
// 2. Add that to deposits
//  3. Be able to pull Aura token
// 4. Factory

contract SingleSidedBalancer is BaseHealthCheck {
    using SafeERC20 for ERC20;

    address internal constant balancerVault =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    
    address internal constant depositWrapper =
        0xcE66E8300dC1d1F5b0e46E9145fDf680a7E41146;

    address internal constant bal = 
        0x9a71012B13CA4d3D0Cdc72A177DF3ef03b0E76A3;
    address internal constant aura = 
        0x1509706a6c66CA549ff0cB464de88231DDBe213B;
    
    IConvexRewards public immutable rewardsContract;

    address public immutable pool;

    bytes32 public immutable poolId;

    uint256 internal immutable length;
    
    uint256 internal immutable spot;

    uint256 internal immutable scaler;

    IAsset[] internal tokens;

    uint256 public maxSingleTrade;

    constructor(
        address _asset,
        string memory _name,
        address _pool,
        address _rewardsContract,
        uint256 _maxSingleTrade
    ) BaseHealthCheck(_asset, _name) {
        rewardsContract = IConvexRewards(_rewardsContract);

        pool = _pool;
        poolId = IBalancerPool(_pool).getPoolId();
        (IERC20[] memory _tokens, , ) = IBalancerVault(balancerVault)
            .getPoolTokens(poolId);

        (tokens, length, spot) = _setLengthAndSpot(_tokens);

        scaler = 10 ** (ERC20(pool).decimals() - asset.decimals());

        maxSingleTrade = _maxSingleTrade;

        _setLossLimitRatio(100);

        asset.safeApprove(depositWrapper, type(uint256).max);
        ERC20(bal).safeApprove(balancerVault, type(uint256).max);
    }

    function _setLengthAndSpot(IERC20[] memory _tokens)
        internal
        view
        returns (
            IAsset[] memory tokens_,
            uint256 _length,
            uint256 _spot
        )
    {
        _length = _tokens.length;
        tokens_ = new IAsset[](_length);

        for (uint256 i = 0; i < _length; ++i) {
            tokens_[i] = IAsset(address(_tokens[i]));
            if (_tokens[i] == IERC20(address(asset))) {
                _spot = i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        IAsset[] memory _assets = new IAsset[](length);
        uint256[] memory _maxAmountsIn = new uint256[](length);

        _assets = tokens;
        _maxAmountsIn[spot] = _amount;

        uint256[] memory amountsIn = new uint256[](length - 1);
        amountsIn[spot] = _amount;

        bytes memory data = abi.encode(
            IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
            amountsIn,
            0
        );

        IBalancerVault.JoinPoolRequest memory _request = IBalancerVault
            .JoinPoolRequest({
                assets: _assets,
                maxAmountsIn: _maxAmountsIn,
                userData: data,
                fromInternalBalance: false
            });

        IRewardPoolDepositWrapper(depositWrapper).depositSingle(
            address(rewardsContract),
            asset,
            _amount,
            poolId,
            _request
        );
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // Get the rate of asset to token.
        uint256 _amountBpt = Math.min(
            fromAssetToBpt(_amount),
            totalLpBalance()
        );

        _withdrawLP(Math.min(
            _amountBpt,
            balanceOfStake()
        ));

        IAsset[] memory _assets = new IAsset[](length);
        uint256[] memory _minAmountsOut = new uint256[](length);

        _assets = tokens;

        bytes memory data = abi.encode(
            IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT,
            _amountBpt,
            spot
        );

        IBalancerVault.ExitPoolRequest memory _request = IBalancerVault
            .ExitPoolRequest({
                assets: _assets,
                minAmountsOut: _minAmountsOut,
                userData: data,
                toInternalBalance: false
            });

        IBalancerVault(balancerVault).exitPool(
            poolId,
            address(this),
            payable(address(this)),
            _request
        );
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {   
        _claimAndSellRewards();

        uint256 looseAsset = asset.balanceOf(address(this));

        if (looseAsset != 0) {
            _deployFunds(Math.min(looseAsset, maxSingleTrade));
        }

        _totalAssets =
            asset.balanceOf(address(this)) +
            fromBptToAsset(totalLpBalance());
    }

    function fromAssetToBpt(uint256 _amount) public view returns (uint256) {
        return _amount * 1e18 * scaler / IBalancerPool(pool).getRate();
    }

    function fromBptToAsset(uint256 _amount) public view returns (uint256) {
        return _amount * IBalancerPool(pool).getRate() / 1e18 / scaler;
    }

    /**
    * @notice
    *   Public function that will return the total LP balance held by the Tripod
    * @return both the staked and un-staked balances
    */
    function totalLpBalance() public view returns (uint256) {
        unchecked {
            return balanceOfPool() + balanceOfStake();
        }
    }

    /**
     * @notice
     *  Function returning the liquidity amount of the LP position
     *  This is just the non-staked balance
     * @return balance of LP token
     */
    function balanceOfPool() public view returns (uint256) {
        return ERC20(pool).balanceOf(address(this));
    }

    /**
     * @notice will return the total staked balance
     *   Staked tokens in convex are treated 1 for 1 with lp tokens
     */
    function balanceOfStake() public view returns (uint256) {
        return rewardsContract.balanceOf(address(this));
    }

    /**
     * @notice
     *  Function used internally to collect the accrued rewards mid epoch
     */
    function _getReward() internal {
        rewardsContract.getReward(address(this), false);
    }

    /**
     * @notice
     *   Internal function to un-stake tokens from Convex
     *   harvest Extras will determine if we claim rewards, normally should be true
     */
    function _withdrawLP(uint256 amount) internal {
        if (amount == 0) return;

        rewardsContract.withdrawAndUnwrap(amount, false);
    }

    function _claimAndSellRewards() internal {
        _getReward();
        _swapRewardTokens();
    }

    /**
     * @notice
     *   Overwritten main function to sell bal and aura with batchSwap
     *   function used internally to sell the available Bal and Aura tokens
     *   We sell bal/Aura -> WETH -> toSwapTo
     */
    function _swapRewardTokens() internal {
        uint256 balBalance = ERC20(bal).balanceOf(address(this));
        //Cant swap 0
        if (balBalance == 0) return;

        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        IAsset[] memory assets = new IAsset[](2);
        int[] memory limits = new int[](2);

        swaps[0] = IBalancerVault.BatchSwapStep(
            0x0297e37f1873d2dab4487aa67cd56b58e2f27875000100000000000000000002, //bal pool id
            0,  //Index to use for Bal
            1,  //index to use for asset
            balBalance,
            abi.encode(0)
        );

        assets[0] = IAsset(bal);
        assets[1] = IAsset(address(asset));
        limits[0] = int(balBalance);

        IBalancerVault(balancerVault).batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, 
            swaps,
            assets,
            _getFundManagement(), 
            limits, 
            block.timestamp
        );   
    }

    function _getFundManagement()
        internal
        view
        returns (IBalancerVault.FundManagement memory fundManagement)
    {
        fundManagement = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(address(this)),
            false
        );
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     */
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        return maxSingleTrade;
    }
    

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        return TokenizedStrategy.totalIdle() + maxSingleTrade;
    }

    // Can also be used to pause deposits.
    function setMaxSingleTrade(uint256 _maxSingleTrade) external onlyEmergencyAuthorized {
        maxSingleTrade = _maxSingleTrade;
    }
    

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        _freeFunds(Math.min(_amount, maxSingleTrade));
    }
}
