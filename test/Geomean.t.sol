// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Geomean} from "../src/Geomean.sol";

contract GeomeanTest is Test {
    Geomean internal token;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new Geomean();
    }

    function test_MetadataAndEntireSupplyToActualDeployer() public {
        assertEq(token.name(), "Geomean");
        assertEq(token.symbol(), "GEOM");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        vm.prank(ALICE);
        Geomean other = new Geomean();
        assertEq(other.balanceOf(ALICE), other.totalSupply());
        assertEq(other.balanceOf(address(this)), 0);
    }

    function testFuzz_TransferAndAllowanceConserveSupply(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.approve(ALICE, amount));
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, amount));
        assertEq(token.allowance(address(this), ALICE), 0);
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        vm.prank(BOB);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_RejectsInsufficientBalanceAllowanceAndZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_InfiniteAllowanceAndZeroTransfer() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 10);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 10);
    }

    function test_NoMintAdminOrUpgradeSelectorsEvenForDeployer() public {
        string[11] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "burn(uint256)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            bytes memory data = abi.encodeWithSignature(selectors[i], ALICE, 100 ether);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, selectors[i]);
            vm.prank(ALICE);
            (ok,) = address(token).call(data);
            assertFalse(ok, selectors[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_NoForbiddenRuntimeOpcodes() public view {
        bytes memory code = address(token).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}
