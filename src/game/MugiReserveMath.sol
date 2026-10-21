// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared constructor-only reserve bound; performs no external calls.
library MugiReserveMath {
    error InvalidInitialSupply();

    /// @dev Let I be each crew's initial allocation and M = int128.max. Across
    /// ten crews and nine eliminations, external token mass is at most 10I+45M:
    /// 10 seeds and 9+8+...+1 matched-LP additions, each quote capped at M.
    /// Fix one crew X. A source unit can enter X through conversion at most
    /// once: X cannot convert out while alive and receives nothing after dying.
    /// Each conversion distributes only 75% in aggregate. Thus X's initial,
    /// matched-LP and incoming conversion releases together cannot exceed that
    /// source bound, plus at most nine units of conservative escrow rounding.
    /// 10I+100M leaves more than that rounding allowance. Claims materialize
    /// existing escrow and do not allocate a second reserve release.
    ///
    /// This proof requires the hook to enforce nine distinct eliminations,
    /// one reinforcement per survivor per round, quote <= M, and no arbitrary
    /// reserve release. Unreleased reserve is excluded from every eligibility
    /// snapshot and from the future V2 handoff.
    function reserveFor(uint256 initialSupply) internal pure returns (uint256) {
        if (initialSupply < 1000 || initialSupply > 1e36) revert InvalidInitialSupply();
        return 10 * initialSupply + 100 * uint256(uint128(type(int128).max));
    }
}
