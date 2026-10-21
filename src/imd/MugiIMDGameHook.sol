// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {MugiIMDLedger} from "./modules/MugiIMDLedger.sol";
import {MugiIMDV4Engine as MugiV4Engine} from "./modules/MugiIMDV4Engine.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MugiIMDBuybacks as MugiBuybacks} from "./modules/MugiIMDBuybacks.sol";
import {MugiIMDPriceOracle as MugiPriceOracle} from "./modules/MugiIMDPriceOracle.sol";
import {MugiCrewToken} from "../../src/game/MugiCrewToken.sol";
import {MugiAirdrop} from "../../src/game/MugiAirdrop.sol";

interface IMugiRandomness {
    function requestRandomness() external returns (uint256);
    function fulfilledAt(uint256 requestId) external view returns (uint64);
}
interface IMugiV2FinaleReceiver {
    function receiveV1Finale(uint8 survivor, address survivorToken, uint256 survivorTokens) external payable;
}

/// @notice Shared, non-upgradeable season controller and Uniswap v4 hook.
/// @dev Immutable-bound CALL modules replace linked libraries. The engine owns LP positions;
/// withdrawals and swap proceeds return here, with all rewards and treasury liabilities retained here.
contract MugiIMDGameHook {
    using TransientStateLibrary for IPoolManager;

    // beforeInitialize, beforeAdd/RemoveLiquidity, before/afterSwap, beforeDonate,
    // before/afterSwap return deltas. Self-initiated PoolManager calls skip hooks.
    uint160 public constant HOOK_FLAGS = 0x2aec;
    uint256 public constant WINDOW = 22 hours;
    uint256 public constant FINAL_CLAIM_WINDOW = 30 days;
    uint256 public constant RANDOMNESS_TIMEOUT = 7 days;
    enum Phase { Setup, Live, AwaitingRandomness, OutcomeReady, Settling, Finalized, Aborted, EmergencyUnwinding, EmergencyClosed }
    address public owner;
    address public pendingOwner;
    address public immutable teamTreasury;
    address public immutable communityTreasury;
    IPoolManager public immutable poolManager;
    uint256 public immutable initialSupply;
    address public immutable v2MigrationTarget;
    address public randomnessProvider;
    address public imdVerifier;
    MugiAirdrop public airdrop;
    address[10] public tokens;
    Phase public phase;
    uint16 public aliveMask = 1023;
    uint16 public seededMask;
    uint8 public eliminations;
    uint8 public defeatedCrew;
    uint8 public settlementCursor;
    uint64 public launchedAt;
    uint64 public configuredAt;
    uint64 public nextCutoff;
    uint64 public claimsExpireAt;
    uint256 public pendingRequest;
    uint256 public teamEth;
    uint256[10] public teamTokens;
    uint256[10] public treasure;
    uint256[10] public ownBurnBudget;
    uint64[10] public ownLastTrade;
    bool private pauseRequested;
    uint64 public pauseUntil;
    uint8 public pauseRound;
    bool public airdropRetired;
    bool public migrated;
    uint256 public settlementLiquidityEth;
    uint256 public settlementBuybackEth;
    bool private entered;
    bool private protocolTransfer;
    MugiIMDLedger public ledger;
    MugiV4Engine public engine;
    uint256 private hookFeeClaims;
    bytes32 private pendingFeeWithdrawal;
    MugiBuybacks public budgets;
    MugiPriceOracle public prices;

    error Unauthorized();
    error InvalidState();
    error InvalidConfiguration();
    error TransferFrozen();
    error EthTransferFailed();
    event SeasonConfigured(address[10] tokens, address airdrop, address randomnessProvider, address imdVerifier);
    event PoolSeeded(uint8 indexed crew, uint256 ethUsed, uint256 tokenUsed);
    event LiquidityDeferred(uint8 indexed crew, uint256 ethAmount);
    event SeasonLaunched(uint64 timestamp, uint64 cutoff);
    event EliminationRequested(uint8 indexed round, uint256 indexed requestId, uint16 aliveMask);
    event OutcomeRecorded(uint8 indexed round, uint256 indexed requestId, uint8 indexed defeatedCrew);
    event RoundSettled(uint8 indexed round, uint8 indexed defeatedCrew, uint16 survivors, uint256 buybackBudget);
    event MigrationRecorded(uint8 indexed round, uint8 indexed defeatedCrew, uint256 treasureAllocated, uint256 retiredTokens, uint256[10] escrowMinted);
    event LiquidityReinforced(uint8 indexed round, uint8 indexed crew, uint256 ethPrincipal, uint256 tokenPrincipal, uint128 liquidity);
    event TeamFeesAccrued(uint8 indexed crew, uint256 ethAmount, uint256 tokenAmount);
    event TeamTokenFeesPaid(uint8 indexed crew, uint256 amount);
    event TokensClaimed(address indexed account, uint8 indexed crew, uint256 amount);
    event BuybackExecuted(uint64 indexed roundId, uint8 indexed crew, uint256 ethSpent, uint256 tokensBurned, bool ownBudget);
    event GameFee(uint8 indexed crew, uint256 ownBurn, uint256 treasureAmount);
    event EthClaimed(address indexed account, address indexed recipient, uint256 amount);
    event FinalClaimsExpired(uint64 indexed deadline, uint256 expiredEth);
    event PauseChanged(bool paused);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event EmergencyRecoveryStarted(uint256 indexed requestId, uint64 deadline);
    event EmergencyRecoveryClosed(uint16 aliveMask, uint256 recoveryEth, uint64 claimsDeadline);

    constructor(
        address owner_, IPoolManager manager_, address team_, address community_, address v2MigrationTarget_, uint256 initialSupply_
    ) {
        if (owner_ == address(0) || team_ == address(0) || community_ == address(0) || address(manager_).code.length == 0
            || (v2MigrationTarget_ != address(0) && v2MigrationTarget_.code.length == 0)
            || initialSupply_ < 1000 || initialSupply_ > 1e36 || (uint160(address(this)) & 0x3fff) != HOOK_FLAGS)
            revert InvalidConfiguration();
        owner = owner_; poolManager = manager_; teamTreasury = team_; communityTreasury = community_;
        initialSupply = initialSupply_;
        v2MigrationTarget = v2MigrationTarget_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }
    modifier onlyManager() { if (msg.sender != address(poolManager)) revert Unauthorized(); _; }
    modifier guarded() { _enter(); _; entered = false; }
    function _enter() private {
        if (entered || poolManager.isUnlocked()) revert InvalidState();
        entered = true;
    }
    receive() external payable {}

    /// @notice A replacement wallet must accept before any owner privilege moves.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0) || newOwner == owner) revert InvalidConfiguration();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        pendingOwner = address(0);
        emit OwnershipTransferStarted(owner, address(0));
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    function configure(address[10] calldata tokens_, MugiAirdrop airdrop_, address randomness_, address imd_) external onlyOwner guarded {
        if (phase != Phase.Setup || address(ledger) == address(0) || tokens[0] != address(0) || address(airdrop_).code.length == 0
            || randomness_.code.length == 0 || (imd_ != address(0) && imd_.code.length == 0)
            || airdrop_.hook() != address(this) || airdrop_.initialSupply() != initialSupply) revert InvalidConfiguration();
        tokens = tokens_; airdrop = airdrop_; randomnessProvider = randomness_; imdVerifier = imd_;
        configuredAt = uint64(block.timestamp);
        ledger.initializeSeason(tokens_, address(airdrop_), address(engine), teamTreasury, communityTreasury, address(poolManager));
        emit SeasonConfigured(tokens_, address(airdrop_), randomness_, imd_);
    }

    /// @notice One-time owner binding of separately deployed, hook-authorized accounting modules.
    /// @dev Must precede configuration. Modules never hold LP assets or receive owner authority.
    function bindAccounting(MugiIMDLedger ledger_, MugiBuybacks budgets_, MugiPriceOracle prices_, MugiV4Engine engine_) external onlyOwner guarded {
        if (address(ledger) != address(0) || tokens[0] != address(0) || phase != Phase.Setup
            || ledger_.hook() != address(this) || budgets_.hook() != address(this) || prices_.hook() != address(this)
            || engine_.hook() != address(this) || address(engine_.manager()) != address(poolManager))
            revert InvalidConfiguration();
        ledger = ledger_; budgets = budgets_; prices = prices_; engine = engine_;
        emit AccountingBound(address(ledger_), address(budgets_), address(prices_), address(engine_));
    }
    event AccountingBound(address ledger, address budgets, address prices, address engine);

    /// @notice Initial supply is split 95/5. Unusable LP token rounding dust remains excluded inventory.
    function seedPool(uint8 crew) external payable onlyOwner guarded {
        if (phase != Phase.Setup || tokens[0] == address(0) || crew >= 10 || msg.value == 0
            || msg.value > 1e30 || (seededMask & (uint16(1) << crew)) != 0) revert InvalidState();
        uint256 drop = initialSupply / 20;
        uint256 lpTokens = initialSupply - drop;
        uint128 liquidity = engine.registerInitialPool(crew, tokens[crew], lpTokens, msg.value);
        protocolTransfer = true;
        MugiCrewToken(tokens[crew]).mint(address(this), lpTokens);
        MugiCrewToken(tokens[crew]).mint(address(airdrop), drop);
        MugiCrewToken(tokens[crew]).transfer(address(engine), lpTokens);
        MugiV4Engine.LiquidityResult memory result = engine.addLiquidity{value: msg.value}(crew, liquidity, msg.value, lpTokens);
        protocolTransfer = false;
        _fees(crew, result.ethFees, result.tokenFees);
        seededMask |= uint16(1) << crew;
        _observe(crew);
        emit PoolSeeded(crew, result.ethPrincipal, result.tokenPrincipal);
    }

    /// @notice Permissionless activation once verified participation reaches the
    /// threshold, or seven days after configuration. No agent owner key is needed.
    function launch() external guarded {
        if (phase != Phase.Setup || seededMask != 1023 || !airdrop.launchEligible(configuredAt)) revert InvalidState();
        phase = Phase.Live; launchedAt = uint64(block.timestamp); nextCutoff = uint64(block.timestamp + 1 days);
        airdrop.launch(); emit SeasonLaunched(launchedAt, nextCutoff);
    }

    /// @notice Cancels an unlaunched season and returns only its seeded LP ETH to
    /// the current owner. An ownership handover transfers this prelaunch refund
    /// right too. It is impossible after `launch()`, so it
    /// cannot seize live player liquidity, treasury rewards or player claims.
    function abortPrelaunch() external onlyOwner guarded {
        if (phase != Phase.Setup) revert InvalidState();
        protocolTransfer = true;
        for (uint8 i; i < 10; ++i) {
            if ((seededMask & (uint16(1) << i)) == 0) continue;
            engine.removeLiquidity(i, 0, 0);
        }
        protocolTransfer = false;
        phase = Phase.Aborted;
        uint256 refund = address(this).balance;
        _pay(payable(owner), refund);
    }

    /// @notice One emergency trading pause per round, lasting at most one hour.
    /// Early release never restores the round's allowance; expiry needs no owner.
    function setPaused(bool value) external onlyOwner {
        if (value) {
            if (phase != Phase.Live || block.timestamp >= nextCutoff || pauseRound == eliminations + 1) revert InvalidState();
            pauseRound = eliminations + 1;
            pauseUntil = uint64(block.timestamp + 1 hours);
            if (pauseUntil > nextCutoff) pauseUntil = nextCutoff;
        }
        pauseRequested = value; emit PauseChanged(value);
    }

    function paused() public view returns (bool) { return pauseRequested && block.timestamp < pauseUntil; }

    /// @notice Fixed at the round cutoff, including when no request can be accepted.
    function randomnessDeadline() public view returns (uint64) { return uint64(nextCutoff + RANDOMNESS_TIMEOUT); }

    /// @notice Fixed clock cutoff applies even when nobody submits this transaction promptly.
    function requestElimination() external guarded {
        if (phase != Phase.Live || eliminations >= 9 || block.timestamp < nextCutoff
            || block.timestamp >= randomnessDeadline()) revert InvalidState();
        phase = Phase.AwaitingRandomness;
        pendingRequest = IMugiRandomness(randomnessProvider).requestRandomness();
        emit EliminationRequested(eliminations + 1, pendingRequest, aliveMask);
    }

    /// @notice VRF callback stores one result only; it cannot touch LPs or execute purchases.
    function receiveRandomness(uint256 requestId, uint256 word) external {
        if (msg.sender != randomnessProvider) revert Unauthorized();
        if (phase != Phase.AwaitingRandomness || requestId != pendingRequest) revert InvalidState();
        // A word first stored at/after the precommitted deadline cannot revive
        // the season. An on-time word with deferred delivery remains mandatory.
        uint64 deadline = randomnessDeadline();
        if (block.timestamp >= deadline) {
            uint64 received = IMugiRandomness(randomnessProvider).fulfilledAt(requestId);
            if (received == 0 || received >= deadline) return;
        }
        uint256 index = word % (10 - eliminations);
        for (uint8 i; i < 10; ++i) {
            if ((aliveMask & (uint16(1) << i)) == 0) continue;
            if (index == 0) { defeatedCrew = i; break; }
            --index;
        }
        phase = Phase.OutcomeReady;
        emit OutcomeRecorded(eliminations + 1, requestId, defeatedCrew);
    }

    /// @notice No reroll: an overdue unfulfilled request closes the season through
    /// bounded LP withdrawals. Existing ETH claims/team fees stay reserved. The
    /// remainder is shared equally between live crews and pro rata within each
    /// crew's frozen wallet-plus-virtual economic supply. No arbitrary winner or
    /// owner withdrawal is introduced. Unallocated shares expire to community.
    function recoverStalledRandomness(uint8 maxPools) external guarded {
        if (maxPools == 0 || maxPools > 10) revert InvalidState();
        if (phase == Phase.AwaitingRandomness || (phase == Phase.Live && eliminations < 9)) {
            uint64 deadline = randomnessDeadline();
            if (block.timestamp < deadline) revert InvalidState();
            if (phase == Phase.AwaitingRandomness) {
                uint64 received = IMugiRandomness(randomnessProvider).fulfilledAt(pendingRequest);
                if (received != 0 && received < deadline) revert InvalidState();
            } else pendingRequest = 0;
            phase = Phase.EmergencyUnwinding; settlementCursor = 0;
            emit EmergencyRecoveryStarted(pendingRequest, deadline);
        }
        if (phase != Phase.EmergencyUnwinding) revert InvalidState();
        protocolTransfer = true; _materializeFees();
        uint8 done;
        while (settlementCursor < 10 && done < maxPools) {
            uint8 crew = settlementCursor++;
            if ((aliveMask & (uint16(1) << crew)) == 0) continue;
            MugiV4Engine.LiquidityResult memory removed = engine.removeLiquidity(crew, 0, 0);
            _fees(crew, removed.ethFees, removed.tokenFees);
            ++done;
        }
        protocolTransfer = false;
        if (settlementCursor == 10) {
            uint256 recoveryEth = address(this).balance - teamEth - ledger.reservedEth();
            ledger.emergencyFinalize(aliveMask, recoveryEth);
            phase = Phase.EmergencyClosed;
            claimsExpireAt = uint64(block.timestamp + FINAL_CLAIM_WINDOW);
            emit EmergencyRecoveryClosed(aliveMask, recoveryEth, claimsExpireAt);
        }
    }

    /// @notice Permissionless bounded settlement. Reverts preserve the recorded outcome and completed batches.
    function settleRound(uint8 maxPools) external guarded {
        if (maxPools == 0 || maxPools > 10 || (phase != Phase.OutcomeReady && phase != Phase.Settling)) revert InvalidState();
        protocolTransfer = true;
        if (phase == Phase.OutcomeReady) _beginSettlement();
        uint8 done;
        while (settlementCursor < 10 && done < maxPools) {
            uint8 crew = settlementCursor++;
            if ((aliveMask & (uint16(1) << crew)) == 0) continue;
            uint256 count = 10 - eliminations;
            uint256 share = settlementLiquidityEth / count;
            if (share != 0) _addMatchedLiquidity(crew, share);
            ++done;
        }
        protocolTransfer = false;
        if (settlementCursor == 10) {
            budgets.create(eliminations, settlementBuybackEth, aliveMask);
            nextCutoff = uint64(block.timestamp + 1 days); phase = Phase.Live;
            emit RoundSettled(eliminations, defeatedCrew, aliveMask, settlementBuybackEth);
        }
    }

    function _beginSettlement() private {
        _materializeFees();
        uint8 loser = defeatedCrew;
        MugiV4Engine.LiquidityResult memory removed = engine.removeLiquidity(loser, 0, 0);
        _fees(loser, removed.ethFees, removed.tokenFees);
        _payTeamTokenFees(loser);
        uint256 allocatedTreasure = treasure[loser];
        (uint256[10] memory minted,) = ledger.recordElimination(loser, aliveMask, allocatedTreasure);
        treasure[loser] = 0;
        // All hook-held loser units are protocol inventory or old escrow. Retire once.
        uint256 retired = MugiCrewToken(tokens[loser]).balanceOf(address(this));
        MugiCrewToken(tokens[loser]).burn(address(this), retired);
        aliveMask &= ~(uint16(1) << loser);
        ++eliminations;
        for (uint8 i; i < 10; ++i) if (minted[i] != 0) MugiCrewToken(tokens[i]).mint(address(this), minted[i]);
        emit MigrationRecorded(eliminations, loser, allocatedTreasure, retired, minted);
        settlementLiquidityEth = removed.ethPrincipal / 2;
        settlementBuybackEth = removed.ethPrincipal - settlementLiquidityEth + ownBurnBudget[loser];
        ownBurnBudget[loser] = 0; settlementCursor = 0; phase = Phase.Settling;
    }

    function _addMatchedLiquidity(uint8 crew, uint256 ethAmount) private {
        (uint128 liquidity,, uint256 needed) = engine.quoteLiquidityForEth(crew, ethAmount);
        // A sub-liquidity-unit or out-of-range contribution cannot be represented
        // by the fixed position. Preserve this ETH for finale instead of freezing
        // the entire season; all other engine failures still revert settlement.
        if (liquidity == 0) {
            emit LiquidityDeferred(crew, ethAmount);
            return;
        }
        MugiCrewToken token = MugiCrewToken(tokens[crew]);
        token.mint(address(this), needed);
        token.transfer(address(engine), needed);
        MugiV4Engine.LiquidityResult memory result = engine.addLiquidity{value: ethAmount}(crew, liquidity, ethAmount, needed);
        if (needed > result.tokenPrincipal) token.burn(address(this), needed - result.tokenPrincipal);
        _fees(crew, result.ethFees, result.tokenFees);
        _observe(crew);
        emit LiquidityReinforced(eliminations, crew, result.ethPrincipal, result.tokenPrincipal, liquidity);
    }

    function approvePlan(MugiBuybacks.BuybackPlan calldata plan, bytes calldata proof) external guarded {
        if (phase != Phase.Live || block.timestamp >= nextCutoff || plan.roundId != eliminations) revert InvalidState();
        budgets.approve(plan, imdVerifier, proof);
    }

    function executeBuyback(uint64 roundId, uint8 crew, uint256 ethAmount) external guarded {
        _requireLive(crew);
        if (roundId != eliminations || roundId == 0) revert InvalidState();
        budgets.authorize(roundId, crew, ethAmount);
        (uint256 spent, uint256 burned) = _buyAndBurn(crew, ethAmount);
        budgets.account(roundId, crew, spent);
        emit BuybackExecuted(roundId, crew, spent, burned, false);
    }

    function executeOwnBuyback(uint8 crew, uint256 ethAmount) external guarded {
        _requireLive(crew);
        uint256 minimum = ownBurnBudget[crew] / 100;
        if (ownBurnBudget[crew] % 100 != 0) ++minimum;
        // Keep the same 22-hour execution window in every round, including the opening round.
        if (block.timestamp >= nextCutoff - 2 hours || ethAmount == 0 || ethAmount < minimum
            || ethAmount > (ownBurnBudget[crew] + 19) / 20
            || ethAmount > ownBurnBudget[crew] || (ownLastTrade[crew] != 0 && block.timestamp < ownLastTrade[crew] + 5 minutes))
            revert InvalidState();
        ownLastTrade[crew] = uint64(block.timestamp);
        (uint256 spent, uint256 burned) = _buyAndBurn(crew, ethAmount);
        if (spent < minimum) revert InvalidState();
        ownBurnBudget[crew] -= spent;
        emit BuybackExecuted(eliminations, crew, spent, burned, true);
    }

    function _buyAndBurn(uint8 crew, uint256 ethAmount) private returns (uint256 spent, uint256 burned) {
        _materializeFees();
        (, int24 tick,) = engine.getPoolState(crew);
        prices.update(crew, tick);
        (uint256 minimum, uint160 limit) = prices.quoteMinimum(crew, ethAmount, tick);
        protocolTransfer = true;
        (spent, burned) = engine.buy{value: ethAmount}(crew, ethAmount, minimum, limit);
        MugiCrewToken(tokens[crew]).burn(address(this), burned);
        protocolTransfer = false;
        _observe(crew);
    }

    function retireAirdrop() external guarded {
        if (launchedAt == 0 || block.timestamp < launchedAt + WINDOW || airdropRetired) revert InvalidState();
        airdropRetired = true; protocolTransfer = true;
        for (uint8 i; i < 10; ++i) MugiCrewToken(tokens[i]).burn(address(airdrop), MugiCrewToken(tokens[i]).balanceOf(address(airdrop)));
        protocolTransfer = false;
    }

    function claimTokens() external guarded returns (uint256[10] memory amounts) {
        _requireClaims(); amounts = ledger.claimTokens(msg.sender); protocolTransfer = true;
        for (uint8 i; i < 10; ++i) {
            if (amounts[i] != 0) {
                MugiCrewToken(tokens[i]).transfer(msg.sender, amounts[i]);
                emit TokensClaimed(msg.sender, i, amounts[i]);
            }
        }
        protocolTransfer = false;
    }

    function claimToken(uint8 crew, uint256 amount) external guarded {
        _requireClaims(); ledger.claimToken(msg.sender, crew, amount); protocolTransfer = true;
        MugiCrewToken(tokens[crew]).transfer(msg.sender, amount); protocolTransfer = false;
        emit TokensClaimed(msg.sender, crew, amount);
    }

    function claimEth(address payable recipient) external guarded returns (uint256 amount) {
        _requireEthClaim();
        if (recipient == address(0)) revert InvalidConfiguration();
        amount = ledger.claimEth(msg.sender); _materializeFees();
        _pay(recipient, amount); emit EthClaimed(msg.sender, recipient, amount);
    }

    function collectTeamFees(uint8 crew) external guarded {
        if (crew >= 10 || phase != Phase.Live || block.timestamp >= nextCutoff || (aliveMask & (uint16(1) << crew)) == 0)
            revert InvalidState();
        protocolTransfer = true;
        (uint256 ethFee, uint256 tokenFee) = engine.collectFees(crew);
        protocolTransfer = false; _fees(crew, ethFee, tokenFee);
    }

    function withdrawTeamFees() external guarded {
        _requireTeamWithdrawal(); uint256 ethAmount = teamEth; teamEth = 0; protocolTransfer = true;
        for (uint8 i; i < 10; ++i) _payTeamTokenFees(i);
        protocolTransfer = false; _pay(payable(teamTreasury), ethAmount);
    }

    function finalize() external guarded {
        if (phase != Phase.Live || eliminations != 9 || block.timestamp < nextCutoff) revert InvalidState();
        uint8 survivor;
        while ((aliveMask & (uint16(1) << survivor)) == 0) ++survivor;
        protocolTransfer = true; _materializeFees();
        MugiV4Engine.LiquidityResult memory removed = engine.removeLiquidity(survivor, 0, 0);
        _fees(survivor, removed.ethFees, removed.tokenFees);
        _payTeamTokenFees(survivor);
        ledger.finalizeMigration(survivor);
        protocolTransfer = false;
        phase = Phase.Finalized;
        claimsExpireAt = uint64(block.timestamp + FINAL_CLAIM_WINDOW);
    }

    /// @notice Manual V2 handoff after V2 is deployed and its source binding is set.
    function migrateToV2(address target) external onlyOwner guarded {
        if (phase != Phase.Finalized || migrated || target.code.length == 0
            || (v2MigrationTarget != address(0) && target != v2MigrationTarget)) revert InvalidState();
        migrated = true;
        uint8 survivor;
        while ((aliveMask & (uint16(1) << survivor)) == 0) ++survivor;
        uint256 inventory = MugiCrewToken(tokens[survivor]).balanceOf(address(this)) - ledger.escrowBacking(survivor);
        uint256 ethAmount = address(this).balance - teamEth - ledger.reservedEth();
        protocolTransfer = true;
        MugiCrewToken(tokens[survivor]).transfer(target, inventory);
        protocolTransfer = false;
        IMugiV2FinaleReceiver(target).receiveV1Finale{value: ethAmount}(survivor, tokens[survivor], inventory);
    }

    /// @notice Resolves liabilities that remain after the published 30-day final
    /// claim window. Expired ETH goes to the immutable community treasury and
    /// remaining migration backing is burned; neither can be redirected to owner.
    function sweepExpiredFinalClaims() external guarded {
        uint64 deadline = claimsExpireAt;
        if ((phase != Phase.Finalized && phase != Phase.EmergencyClosed) || deadline == 0 || block.timestamp < deadline) revert InvalidState();
        (uint256 expiredEth, uint256[10] memory expiredTokens) = ledger.expireFinalClaims();
        protocolTransfer = true;
        for (uint8 i; i < 10; ++i) {
            if (expiredTokens[i] != 0) MugiCrewToken(tokens[i]).burn(address(this), expiredTokens[i]);
        }
        protocolTransfer = false;
        claimsExpireAt = 0;
        // Terminal recovery has no V2 handoff: all unallocated shares and dust
        // join expired player claims. No treasury call can block LP recovery.
        if (phase == Phase.EmergencyClosed) expiredEth = address(this).balance - teamEth;
        _pay(payable(communityTreasury), expiredEth);
        emit FinalClaimsExpired(deadline, expiredEth);
    }

    function beforeTokenTransfer(uint8 crew, address from, address to, uint256) external {
        if (crew >= 10 || msg.sender != tokens[crew]) revert Unauthorized();
        if (!protocolTransfer) {
            if (phase != Phase.Live || block.timestamp >= nextCutoff || (aliveMask & (uint16(1) << crew)) == 0
                || from == address(0) || to == address(0)) revert TransferFrozen();
        }
        ledger.beforeBalanceChange(from, to);
    }

    function afterTokenTransfer(uint8 crew, address from, address to, uint256 amount) external {
        if (crew >= 10 || msg.sender != tokens[crew]) revert Unauthorized();
        ledger.afterBalanceChange(crew, from, to, amount);
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view onlyManager returns (bytes4) {
        if (sender != address(engine)) revert Unauthorized();
        return IHooks.beforeInitialize.selector;
    }
    function beforeAddLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external view onlyManager returns (bytes4) {
            if (sender != address(engine)) revert Unauthorized();
            return IHooks.beforeAddLiquidity.selector;
        }
    function beforeRemoveLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external view onlyManager returns (bytes4) {
            if (sender != address(engine)) revert Unauthorized();
            return IHooks.beforeRemoveLiquidity.selector;
        }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external view onlyManager returns (bytes4) { revert Unauthorized(); }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external onlyManager returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint8 crew = engine.crewForPool(key);
        if (sender == address(engine)) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        _requireLive(crew); _observe(crew);
        (BeforeSwapDelta delta, uint256 fee) = engine.beforeSwapFee(params); _gameFee(crew, fee);
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    function afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external onlyManager returns (bytes4, int128)
    {
        uint8 crew = engine.crewForPool(key);
        if (sender == address(engine)) return (IHooks.afterSwap.selector, 0);
        (int128 returned, uint256 fee) = engine.afterSwapFee(params, delta); _gameFee(crew, fee); _observe(crew);
        return (IHooks.afterSwap.selector, returned);
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (pendingFeeWithdrawal == bytes32(0) || keccak256(data) != pendingFeeWithdrawal) revert InvalidState();
        pendingFeeWithdrawal = bytes32(0);
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), address(this), amount);
        return bytes("");
    }
    function _gameFee(uint8 crew, uint256 fee) private {
        if (fee == 0) return;
        hookFeeClaims += fee;
        poolManager.mint(address(this), 0, fee);
        uint256 own = fee / 2; ownBurnBudget[crew] += own; treasure[crew] += fee - own;
        emit GameFee(crew, own, fee - own);
    }
    function _materializeFees() private {
        uint256 amount = hookFeeClaims;
        if (amount == 0) return;
        hookFeeClaims = 0;
        bytes memory data = abi.encode(amount);
        pendingFeeWithdrawal = keccak256(data);
        poolManager.unlock(data);
        if (pendingFeeWithdrawal != bytes32(0)) revert InvalidState();
    }
    function _fees(uint8 crew, uint256 ethFee, uint256 tokenFee) private {
        teamEth += ethFee; teamTokens[crew] += tokenFee;
        if (ethFee != 0 || tokenFee != 0) emit TeamFeesAccrued(crew, ethFee, tokenFee);
    }
    /// @dev Call only while protocolTransfer is enabled. Excluded treasury ownership
    /// survives crew closure without adding reward or migration eligibility.
    function _payTeamTokenFees(uint8 crew) private {
        uint256 amount = teamTokens[crew];
        if (amount == 0) return;
        teamTokens[crew] = 0;
        MugiCrewToken(tokens[crew]).transfer(teamTreasury, amount);
        emit TeamTokenFeesPaid(crew, amount);
    }
    function _observe(uint8 crew) private { (, int24 tick,) = engine.getPoolState(crew); prices.update(crew, tick); }
    function _requireLive(uint8 crew) private view {
        if (crew >= 10 || phase != Phase.Live || paused() || block.timestamp >= nextCutoff || (aliveMask & (uint16(1) << crew)) == 0)
            revert InvalidState();
    }
    function _requireClaims() private view {
        if (phase != Phase.Live && phase != Phase.Finalized && phase != Phase.EmergencyClosed) revert InvalidState();
        if (phase == Phase.Live && block.timestamp >= nextCutoff) revert InvalidState();
        if (phase != Phase.Live && block.timestamp >= claimsExpireAt) revert InvalidState();
    }
    function _requireEthClaim() private view {
        if (phase == Phase.Setup || phase == Phase.Aborted) revert InvalidState();
        if ((phase == Phase.Finalized || phase == Phase.EmergencyClosed) && block.timestamp >= claimsExpireAt) revert InvalidState();
    }
    function _requireTeamWithdrawal() private view {
        if (phase != Phase.Live && phase != Phase.Finalized && phase != Phase.EmergencyClosed) revert InvalidState();
        if (phase == Phase.Live && block.timestamp >= nextCutoff) revert InvalidState();
    }
    function _pay(address payable recipient, uint256 amount) private {
        if (amount != 0) { (bool success,) = recipient.call{value: amount}(""); if (!success) revert EthTransferFailed(); }
    }

    /// @dev Identically named read-only module APIs share the hook's public ABI.
    /// Return the module's ABI bytes directly to avoid repeated array decoding /
    /// encoding; STATICCALL cannot mutate state and reverts propagate unchanged.
    function _forwardView(address target) private view {
        if (target.code.length == 0) revert InvalidConfiguration();
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := staticcall(gas(), target, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            if iszero(ok) { revert(ptr, returndatasize()) }
            return(ptr, returndatasize())
        }
    }

    function previewAccount(address account) external view returns (uint256[10] memory, uint256, uint256[10] memory) { _forwardView(address(ledger)); }
    function eligibleSupply(uint8 crew) external view returns (uint256) { _forwardView(address(ledger)); }
    function reservedPlayerEth() external view returns (uint256) { return ledger.reservedEth(); }
    function escrowBacking(uint8 crew) external view returns (uint256) { _forwardView(address(ledger)); }
    function unredeemedGameFees() external view returns (uint256) { return hookFeeClaims; }
    function poolKey(uint8 crew) external view returns (PoolKey memory) { _forwardView(address(engine)); }
    function poolId(uint8 crew) external view returns (PoolId) { _forwardView(address(engine)); }
    function poolState(uint8 crew) external view returns (uint160, int24, uint128) { _forwardView(address(engine)); }
    function positionLiquidity(uint8 crew) external view returns (uint128) { _forwardView(address(engine)); }
    function buybackTwap(uint8 crew) external view returns (int24 tick, uint32 secondsUsed, uint16 observations) {
        _forwardView(address(prices));
    }
    function planHash(MugiBuybacks.BuybackPlan calldata plan) external view returns (bytes32) { return budgets.hash(plan); }
    function roundBudget(uint64 id) external view returns (MugiBuybacks.Budget memory) { _forwardView(address(budgets)); }
}
