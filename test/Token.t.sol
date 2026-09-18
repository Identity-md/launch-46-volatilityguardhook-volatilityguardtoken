// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {VolatilityGuardToken as Token} from "../src/VolatilityGuardToken.sol";

contract TokenTest is Test {
    Token token;

    function setUp() public {
        token = new Token();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Volatility Guard Lab");
        assertEq(token.symbol(), "VGL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_allowanceAndInfiniteAllowance() public {
        token.approve(address(1), 100);
        vm.prank(address(1));
        token.transferFrom(address(this), address(2), 40);
        assertEq(token.allowance(address(this), address(1)), 60);
        vm.prank(address(1));
        vm.expectRevert(Token.InsufficientAllowance.selector);
        token.transferFrom(address(this), address(2), 61);
        token.approve(address(1), type(uint256).max);
        vm.prank(address(1));
        token.transferFrom(address(this), address(2), 1);
        assertEq(token.allowance(address(this), address(1)), type(uint256).max);
    }

    function test_rejectZeroAndInsufficient() public {
        vm.expectRevert(Token.InvalidRecipient.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(Token.InsufficientBalance.selector);
        token.transfer(address(1), 1e27 + 1);
    }

    function test_noAdminMint() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_transferConserves(uint256 value) public {
        value = bound(value, 0, 1e27);
        token.transfer(address(1), value);
        assertEq(token.balanceOf(address(1)) + token.balanceOf(address(this)), 1e27);
        vm.prank(address(1));
        token.transfer(address(1), value);
        assertEq(token.balanceOf(address(1)), value);
    }
}
