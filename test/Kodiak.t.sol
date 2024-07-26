// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";
import {HoneyVault} from "../src/HoneyVault.sol";
import {HoneyQueen} from "../src/HoneyQueen.sol";
import {Factory} from "../src/Factory.sol";

interface KodiakStaking {
    function stakeLocked(uint256 amount, uint256 secs) external;
    function withdrawLockedAll() external;
    function getReward() external view returns (uint256);
    function lockedLiquidityOf(address account) external view returns (uint256);
    event StakeLocked(address indexed user, uint256 amount, uint256 secs, bytes32 kek_id, address source_address);
    event WithdrawLocked(address indexed user, uint256 amount, bytes32 kek_id, address destination_address);
    event RewardPaid(address indexed user, uint256 reward, address token_address, address destination_address);
}

interface XKDK {
    function redeem(uint256 amount, uint256 duration) external;
    function finalizeRedeem(uint256 redeemIndex) external;
}

contract KodiakTest is Test {
    using LibString for uint256;

    Factory public factory;
    HoneyVault public honeyVault;
    HoneyQueen public honeyQueen;

    uint256 public expiration;
    address public constant THJ = 0x4A8c9a29b23c4eAC0D235729d5e0D035258CDFA7;
    address public constant referral = address(0x5efe5a11);
    address public constant treasury = address(0x80085);

    // IMPORTANT
    // BARTIO ADDRESSES
    ERC20 public constant KDK = ERC20(0xfd27998fa0eaB1A6372Db14Afd4bF7c4a58C5364);
    XKDK public constant xKDK = XKDK(0x414B50157a5697F14e91417C5275A7496DcF429D);
    ERC20 public constant HONEYBERA_LP = ERC20(0x12C195768f65F282EA5F1B5C42755FBc910B0D8F);
    KodiakStaking public constant KODIAK_STAKING = KodiakStaking(0x1878eb1cA6Da5e2fC4B5213F7D170CA668A0E225);

    function setUp() public {
        vm.createSelectFork("https://bartio.rpc.berachain.com/", uint256(1791773));
        expiration = block.timestamp + 30 days;

        vm.startPrank(THJ);
        // setup honeyqueen stuff
        honeyQueen = new HoneyQueen(treasury);
        // prettier-ignore
        honeyQueen.setIsTargetContractAllowed(address(KODIAK_STAKING), true);
        honeyQueen.setIsSelectorAllowed(
            bytes4(keccak256("stakeLocked(uint256,uint256)")),
            "stake",
            address(KODIAK_STAKING),
            true
        );
        honeyQueen.setIsSelectorAllowed(
            bytes4(keccak256("withdrawLockedAll()")),
            "unstake",
            address(KODIAK_STAKING),
            true
        );
        honeyQueen.setIsSelectorAllowed(
            bytes4(keccak256("getReward()")),
            "rewards",
            address(KODIAK_STAKING),
            true
        );
        honeyQueen.setValidator(THJ);

        factory = new Factory(address(honeyQueen));

        honeyVault = factory.clone(THJ, referral, false);


        vm.stopPrank();

        vm.label(address(honeyVault), "HoneyVault");
        vm.label(address(honeyQueen), "HoneyQueen");
        vm.label(address(HONEYBERA_LP), "HONEYBERA_LP");
        vm.label(address(KODIAK_STAKING), "KODIAK_STAKING");
        vm.label(address(this), "Tests");
        vm.label(THJ, "THJ");
    }

    modifier prankAsTHJ() {
        vm.startPrank(THJ);
        _;
        vm.stopPrank();
    }

    function test_stake() prankAsTHJ external {
        // deposit the LP tokens first
        uint LPBalance = HONEYBERA_LP.balanceOf(THJ);
        HONEYBERA_LP.approve(address(honeyVault), LPBalance);
        honeyVault.depositAndLock(address(HONEYBERA_LP), LPBalance, expiration);


        bytes32 expectedKekId = keccak256(
            abi.encodePacked(
                address(honeyVault),
                block.timestamp,
                LPBalance,
                KODIAK_STAKING.lockedLiquidityOf(address(honeyVault))
            )
        );

        // add extra expects?
        vm.expectEmit(true, false, false, true, address(KODIAK_STAKING));
        emit KodiakStaking.StakeLocked(address(honeyVault), LPBalance, 30 days, expectedKekId, address(honeyVault));
        honeyVault.stake(
            address(HONEYBERA_LP),
            address(KODIAK_STAKING),
            LPBalance,
            abi.encodeWithSelector(
                bytes4(keccak256("stakeLocked(uint256,uint256)")),
                LPBalance,
                30 days
            )
        );
    }

    function test_unstakeSingle() prankAsTHJ external {
        uint256 LPBalance = HONEYBERA_LP.balanceOf(THJ);
        HONEYBERA_LP.approve(address(honeyVault), LPBalance);
        honeyVault.depositAndLock(address(HONEYBERA_LP), LPBalance, expiration);

        bytes32 expectedKekId = keccak256(
            abi.encodePacked(
                address(honeyVault),
                block.timestamp,
                LPBalance,
                KODIAK_STAKING.lockedLiquidityOf(address(honeyVault))
            )
        );

        honeyVault.stake(
            address(HONEYBERA_LP),
            address(KODIAK_STAKING),
            LPBalance,
            abi.encodeWithSelector(
                bytes4(keccak256("stakeLocked(uint256,uint256)")),
                LPBalance,
                30 days
            )
        );

        uint256 kdkBalanceBefore = KDK.balanceOf(address(honeyVault));
        // go forward 30 days
        vm.warp(block.timestamp + 30 days);
        vm.expectEmit(true, false, false, true, address(KODIAK_STAKING));
        emit KodiakStaking.WithdrawLocked(address(honeyVault), LPBalance, expectedKekId, address(honeyVault));
        honeyVault.unstake(
            address(HONEYBERA_LP),
            address(KODIAK_STAKING),
            LPBalance,
            abi.encodeWithSelector(bytes4(keccak256("withdrawLockedAll()")))
        );

        // kdk balance of vault should have gone UP
        uint256 kdkBalanceAfter = KDK.balanceOf(address(honeyVault));
        assertGt(kdkBalanceAfter, kdkBalanceBefore);
    }

    function test_claimRewards() prankAsTHJ external {
        uint256 LPBalance = HONEYBERA_LP.balanceOf(THJ);
        HONEYBERA_LP.approve(address(honeyVault), LPBalance);
        honeyVault.depositAndLock(address(HONEYBERA_LP), LPBalance, expiration);

        honeyVault.stake(
            address(HONEYBERA_LP),
            address(KODIAK_STAKING),
            LPBalance,
            abi.encodeWithSelector(
                bytes4(keccak256("stakeLocked(uint256,uint256)")),
                LPBalance,
                30 days
            )
        );

        uint256 kdkBalanceBefore = KDK.balanceOf(address(honeyVault));
        // go forward 30 days
        vm.warp(block.timestamp + 30 days);
        
        honeyVault.claimRewards(address(KODIAK_STAKING), abi.encodeWithSelector(bytes4(keccak256("getReward()"))));
        // kdk balance of vault should have gone UP
        uint256 kdkBalanceAfter = KDK.balanceOf(address(honeyVault));
        assertGt(kdkBalanceAfter, kdkBalanceBefore);
    }

    function test_multipleStakes() prankAsTHJ external {
        uint256 LPBalance = HONEYBERA_LP.balanceOf(THJ);
        HONEYBERA_LP.approve(address(honeyVault), LPBalance);
        honeyVault.depositAndLock(address(HONEYBERA_LP), LPBalance, expiration);

        bytes32 expectedKekId0 = keccak256(
            abi.encodePacked(
                address(honeyVault),
                block.timestamp,
                LPBalance / 2,
                KODIAK_STAKING.lockedLiquidityOf(address(honeyVault))
            )
        );

        honeyVault.stake(
            address(HONEYBERA_LP),
            address(KODIAK_STAKING),
            LPBalance,
            abi.encodeWithSelector(
                bytes4(keccak256("stakeLocked(uint256,uint256)")),
                LPBalance / 2,
                30 days
            )
        );

        // move forward 15 days
        vm.warp(block.timestamp + 15 days);
        // stake the rest
        bytes32 expectedKekId1 = keccak256(
            abi.encodePacked(
                address(honeyVault),
                block.timestamp,
                LPBalance / 2,
                KODIAK_STAKING.lockedLiquidityOf(address(honeyVault))
            )
        );

        honeyVault.stake(
            address(HONEYBERA_LP),
            address(KODIAK_STAKING),
            LPBalance,
            abi.encodeWithSelector(
                bytes4(keccak256("stakeLocked(uint256,uint256)")),
                LPBalance / 2,
                30 days
            )
        );

        // move again 15 days
        vm.warp(block.timestamp + 15 days);

        // should only be able to withdraw HALF as expected
        vm.expectEmit(true, false, false, true, address(KODIAK_STAKING));
        emit KodiakStaking.WithdrawLocked(address(honeyVault), LPBalance / 2, expectedKekId0, address(honeyVault));
        honeyVault.unstake(
            address(HONEYBERA_LP),
            address(KODIAK_STAKING),
            LPBalance / 2,
            abi.encodeWithSelector(bytes4(keccak256("withdrawLockedAll()")))
        );

        // check LP balance of vault
        assertApproxEqRel(HONEYBERA_LP.balanceOf(address(honeyVault)), LPBalance / 2, 1e14); // 1e14 == 0.01%

        // 15 days later again for the rest
        vm.warp(block.timestamp + 15 days);
        // should only be able to withdraw HALF as expected
        vm.expectEmit(true, false, false, true, address(KODIAK_STAKING));
        emit KodiakStaking.WithdrawLocked(address(honeyVault), LPBalance / 2, expectedKekId1, address(honeyVault));
        honeyVault.unstake(
            address(HONEYBERA_LP),
            address(KODIAK_STAKING),
            LPBalance / 2,
            abi.encodeWithSelector(bytes4(keccak256("withdrawLockedAll()")))
        );

        // check LP balance of vault
        assertApproxEqRel(HONEYBERA_LP.balanceOf(address(honeyVault)), LPBalance, 1e14);
    }

    function test_xkdk() prankAsTHJ external {
        // whitelist xkdk
        honeyQueen.setIsTargetContractAllowed(address(xKDK), true);

        // whitelist selectors
        honeyQueen.setIsSelectorAllowed(
            bytes4(keccak256("redeem(uint256,uint256)")),
            "wildcard",
            address(xKDK),
            true
        );
        honeyQueen.setIsSelectorAllowed(
            bytes4(keccak256("finalizeRedeem(uint256)")),
            "wildcard",
            address(xKDK),
            true
        );


        ERC20 XKDK_ERC20 = ERC20(address(xKDK));
        uint256 xkdkBalance = 1e18;
        uint256 kdkBalance = KDK.balanceOf(address(honeyVault));
        StdCheats.deal(address(XKDK_ERC20), address(honeyVault), xkdkBalance);
        uint256 XKDK_balance = XKDK_ERC20.balanceOf(address(honeyVault));

        // start the redeem for 15 days so 0.5x multiplier
        honeyVault.wildcard(
            address(xKDK),
            abi.encodeWithSelector(bytes4(keccak256("redeem(uint256,uint256)")), xkdkBalance, 15 days)
        );

        // ff 15 days
        vm.warp(block.timestamp + 15 days);
        
        // finalize the redeem
        honeyVault.wildcard(
            address(xKDK),
            abi.encodeWithSelector(bytes4(keccak256("finalizeRedeem(uint256)")), 0)
        );

        uint256 expectedBalance = kdkBalance + (xkdkBalance / 2);
        assertEq(KDK.balanceOf(address(honeyVault)), expectedBalance);
    }
}