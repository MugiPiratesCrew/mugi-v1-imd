// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Bounded, lazy accounting for a ten-crew season. All amounts ending in
/// `Scaled` are token wei multiplied by SCALE; ETH amounts are ordinary wei.
/// @dev Only the immutable hook can mutate accounting. The hook must authenticate token callbacks and freeze economic changes
/// across round cutoff/settlement. Token callbacks run before and after EVERY
/// balance mutation, including mint, burn and migration-escrow transfers.
contract MugiIMDLedger {
    uint256 public constant SCALE = 95_126_814_720; // 4**9 * 9!
    uint8 public constant TOKEN_COUNT = 10;
    uint16 private constant ALL_TOKENS = 1023;

    struct Account {
        uint256[10] virtualScaled;
        uint256 earnedEth;
        uint8 cursor;
    }

    struct Round {
        uint256[10] eligibleScaled;
        uint256 rewardPerCrew;
        uint16 survivorMask;
        uint8 survivorCount;
        uint8 loser;
        bool finale;
    }

    struct State {
        address[10] tokens;
        uint256[10] walletScaled;
        uint256[10] virtualScaled;
        uint256[10] escrowBacking;
        mapping(address => bool) excluded;
        mapping(address => Account) accounts;
        Round[10] rounds;
        uint256 reservedEth;
        uint256 unallocatedEth;
        uint16 aliveMask;
        uint8 eventCount;
        uint8 eliminationCount;
        bool initialized;
        bool finalized;
    }

    address public immutable hook;
    State private self;
    error Unauthorized();
    constructor(address hook_) {
        if (hook_ == address(0)) revert InvalidConfiguration();
        hook = hook_;
    }
    modifier onlyHook() { if (msg.sender != hook) revert Unauthorized(); _; }
    function reservedEth() external view returns (uint256) { return self.reservedEth; }
    function escrowBacking(uint8 crew) external view returns (uint256) { return self.escrowBacking[crew]; }

    error InvalidConfiguration();
    error InvalidRound();
    error InvalidToken();
    error InvalidClaim();
    error InexactConversion();

    function initialize(address[10] memory tokens) public onlyHook {
        if (self.initialized) revert InvalidConfiguration();
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            if (tokens[i] == address(0)) revert InvalidConfiguration();
            for (uint8 j; j < i; ++j) {
                if (tokens[i] == tokens[j]) revert InvalidConfiguration();
            }
        }
        self.tokens = tokens;
        self.aliveMask = ALL_TOKENS;
        self.excluded[address(0)] = true;
        self.excluded[hook] = true;
        self.excluded[address(this)] = true;
        self.initialized = true;
    }

    /// @dev Caller additionally enforces pre-launch access. Reclassification after
    /// any round is forbidden here too. Existing balances adjust eligible totals.
    function setExcluded(address account, bool excluded) public onlyHook {
        if (!self.initialized || self.eventCount != 0) revert InvalidConfiguration();
        if (!excluded && (account == address(0) || account == hook || account == address(this))) revert InvalidConfiguration();
        if (self.excluded[account] == excluded) return;
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            uint256 balance = IERC20(self.tokens[i]).balanceOf(account) * SCALE;
            if (excluded) self.walletScaled[i] -= balance;
            else self.walletScaled[i] += balance;
        }
        self.excluded[account] = excluded;
    }

    function beforeBalanceChange(address from, address to) public onlyHook {
        if (!self.initialized) revert InvalidConfiguration();
        _sync(from);
        if (to != from) _sync(to);
    }

    /// @dev No economic supply remains in a defeated token. Its frozen physical
    /// wallet receipts may consequently be burned without changing current totals.
    function afterBalanceChange(uint8 tokenId, address from, address to, uint256 amount) public onlyHook {
        if (!self.initialized || tokenId >= TOKEN_COUNT) revert InvalidToken();
        if (self.finalized || (self.aliveMask & (uint16(1) << tokenId)) == 0 || amount == 0) return;
        bool debit = !self.excluded[from];
        bool credit = !self.excluded[to];
        if (debit == credit) return;
        uint256 scaled = amount * SCALE;
        if (debit) self.walletScaled[tokenId] -= scaled;
        else self.walletScaled[tokenId] += scaled;
    }

    /// @param aliveMask The PRE-elimination alive mask, checked against state.
    /// @return mintRequired Additional physical escrow tokens to mint per crew.
    /// @return oldEscrowBurn Physical loser escrow backing to burn once.
    /// @dev Returned token operations must complete atomically in the caller.
    function recordElimination(uint8 loser, uint16 aliveMask, uint256 treasureWei)
        public onlyHook
        returns (uint256[10] memory mintRequired, uint256 oldEscrowBurn)
    {
        if (
            !self.initialized || self.finalized || self.eliminationCount >= 9 || loser >= TOKEN_COUNT
                || aliveMask != self.aliveMask || (aliveMask & (uint16(1) << loser)) == 0
        ) revert InvalidRound();
        uint16 survivors = aliveMask & ~(uint16(1) << loser);
        uint8 count = _count(survivors);
        if (count == 0) revert InvalidRound();

        Round storage round = self.rounds[self.eventCount];
        round.loser = loser;
        round.survivorMask = survivors;
        round.survivorCount = count;
        _recordRewards(round, treasureWei);

        uint256 allocation = _convert(self.walletScaled[loser] + self.virtualScaled[loser], count);
        oldEscrowBurn = self.escrowBacking[loser];
        self.walletScaled[loser] = 0;
        self.virtualScaled[loser] = 0;
        self.escrowBacking[loser] = 0;
        self.aliveMask = survivors;
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            if ((survivors & (uint16(1) << i)) == 0) continue;
            self.virtualScaled[i] += allocation;
            uint256 needed = _ceilTokens(self.virtualScaled[i]);
            mintRequired[i] = needed - self.escrowBacking[i];
            self.escrowBacking[i] = needed;
        }
        ++self.eventCount;
        ++self.eliminationCount;
    }

    /// @notice Closes final-token materialization when the protocol-owned final
    /// position is handed to the separately deployed V2 game.
    /// @dev Wallet-held V1 receipts are never seized. Their virtual backing is
    /// moved with the hook inventory, so final token claims must be disabled by
    /// the caller in the same transaction.
    function finalizeMigration(uint8 finalToken) public onlyHook {
        if (
            !self.initialized || self.finalized || self.eliminationCount != 9 || finalToken >= TOKEN_COUNT
                || self.aliveMask != (uint16(1) << finalToken)
        ) revert InvalidRound();
        self.walletScaled[finalToken] = 0;
        self.virtualScaled[finalToken] = 0;
        self.escrowBacking[finalToken] = 0;
        self.finalized = true;
    }

    /// @dev The caller immediately transfers returned amounts from its excluded
    /// escrow to account, through the normal token callbacks, in this transaction.
    function claimTokens(address account) public onlyHook returns (uint256[10] memory amounts) {
        _sync(account);
        if (self.excluded[account]) revert InvalidClaim();
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            uint256 amount = self.accounts[account].virtualScaled[i] / SCALE;
            if (amount != 0) {
                _debitVirtual(account, i, amount);
                amounts[i] = amount;
            }
        }
    }

    function claimToken(address account, uint8 tokenId, uint256 amount) public onlyHook returns (uint256) {
        if (tokenId >= TOKEN_COUNT || self.excluded[account]) revert InvalidClaim();
        _sync(account);
        if (amount > self.accounts[account].virtualScaled[tokenId] / SCALE) revert InvalidClaim();
        _debitVirtual(account, tokenId, amount);
        return amount;
    }

    function claimEth(address account) public onlyHook returns (uint256 amount) {
        _sync(account);
        if (self.excluded[account]) revert InvalidClaim();
        amount = self.accounts[account].earnedEth;
        self.accounts[account].earnedEth = 0;
        self.reservedEth -= amount;
    }

    /// @notice Clears final-season liabilities after the hook's immutable claim deadline.
    /// @dev Individual account storage is deliberately not iterated. The hook blocks
    /// later claims before calling this function, and burns exactly the returned
    /// token backing in the same transaction.
    function expireFinalClaims()
        public onlyHook
        returns (uint256 expiredEth, uint256[10] memory expiredTokenBacking)
    {
        if (!self.initialized || !self.finalized) revert InvalidClaim();
        expiredEth = self.reservedEth;
        self.reservedEth = 0;
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            expiredTokenBacking[i] = self.escrowBacking[i];
            self.escrowBacking[i] = 0;
            self.virtualScaled[i] = 0;
        }
    }

    function previewAccount(address account)
        public
        view
        returns (uint256[10] memory claimableTokens, uint256 earnedEth, uint256[10] memory virtualScaled)
    {
        (virtualScaled, earnedEth) = _preview(account);
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            claimableTokens[i] = virtualScaled[i] / SCALE;
        }
    }

    function eligibleSupply(uint8 tokenId) public view returns (uint256) {
        if (tokenId >= TOKEN_COUNT) revert InvalidToken();
        return self.walletScaled[tokenId] + self.virtualScaled[tokenId];
    }

    function _recordRewards(Round storage round, uint256 ethAmount) private {
        uint256 share = ethAmount / round.survivorCount;
        round.rewardPerCrew = share;
        uint256 unallocated = ethAmount - share * round.survivorCount;
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            if ((round.survivorMask & (uint16(1) << i)) == 0) continue;
            uint256 supply = self.walletScaled[i] + self.virtualScaled[i];
            round.eligibleScaled[i] = supply;
            if (supply == 0) unallocated += share;
        }
        self.unallocatedEth += unallocated;
        self.reservedEth += ethAmount - unallocated;
    }

    function _debitVirtual(address account, uint8 tokenId, uint256 amount) private {
        uint256 scaled = amount * SCALE;
        self.accounts[account].virtualScaled[tokenId] -= scaled;
        self.virtualScaled[tokenId] -= scaled;
        self.escrowBacking[tokenId] -= amount;
    }

    function _sync(address account) private {
        if (self.excluded[account] || self.accounts[account].cursor == self.eventCount) return;
        (uint256[10] memory virtualScaled, uint256 earnedEth) = _preview(account);
        self.accounts[account].virtualScaled = virtualScaled;
        self.accounts[account].earnedEth = earnedEth;
        self.accounts[account].cursor = self.eventCount;
    }

    function _preview(address account)
        private
        view
        returns (uint256[10] memory virtualScaled, uint256 earnedEth)
    {
        if (self.excluded[account]) return (virtualScaled, 0);
        Account storage stored = self.accounts[account];
        virtualScaled = stored.virtualScaled;
        earnedEth = stored.earnedEth;
        if (stored.cursor == self.eventCount) {
            if (self.finalized) {
                for (uint8 i; i < TOKEN_COUNT; ++i) virtualScaled[i] = 0;
            }
            return (virtualScaled, earnedEth);
        }

        uint256[10] memory walletScaled;
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            walletScaled[i] = IERC20(self.tokens[i]).balanceOf(account) * SCALE;
        }
        for (uint8 r = stored.cursor; r < self.eventCount; ++r) {
            Round storage round = self.rounds[r];
            for (uint8 i; i < TOKEN_COUNT; ++i) {
                if (round.eligibleScaled[i] == 0) continue;
                earnedEth += Math.mulDiv(
                    round.rewardPerCrew, walletScaled[i] + virtualScaled[i], round.eligibleScaled[i]
                );
            }
            if (round.finale) continue;
            uint256 allocation = _convert(walletScaled[round.loser] + virtualScaled[round.loser], round.survivorCount);
            walletScaled[round.loser] = 0;
            virtualScaled[round.loser] = 0;
            for (uint8 i; i < TOKEN_COUNT; ++i) {
                if ((round.survivorMask & (uint16(1) << i)) != 0) virtualScaled[i] += allocation;
            }
        }
        // Final V1 token rights are not materialized once the final position
        // migrates to V2. Earlier earned ETH has already been accumulated above.
        if (self.finalized) {
            for (uint8 i; i < TOKEN_COUNT; ++i) virtualScaled[i] = 0;
        }
    }

    function _convert(uint256 defeatedScaled, uint8 survivors) private pure returns (uint256) {
        uint256 denominator = uint256(survivors) * 4;
        if (mulmod(defeatedScaled, 3, denominator) != 0) revert InexactConversion();
        return Math.mulDiv(defeatedScaled, 3, denominator);
    }

    function _ceilTokens(uint256 scaled) private pure returns (uint256) {
        return scaled / SCALE + (scaled % SCALE == 0 ? 0 : 1);
    }

    function _count(uint16 mask) private pure returns (uint8 result) {
        for (; mask != 0; mask &= mask - 1) {
            ++result;
        }
    }
}
