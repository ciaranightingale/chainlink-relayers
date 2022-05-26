// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import 'forge-std/Test.sol';
import './utils/RelayCompatibleTestHelper.sol';

contract RelayCompatibleTest is Test {
    RelayCompatibleTestHelper public relayCompatible;

    bytes32 public constant emptyCheckDataHash =
        0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    function setUp() public {
        relayCompatible = new RelayCompatibleTestHelper();
        vm.label(address(this), 'this');
        vm.label(address(relayCompatible), 'relayCompatible');
    }

    function test_cannotExecute() public {
        vm.expectRevert(abi.encodeWithSignature('OnlySimulatedBackend()'));
        relayCompatible.helperCannotExecute();
    }

    function test_msgSenderBase() public {
        // empty data from this
        address sender = relayCompatible.msgSenderBase();
        assertEq(sender, address(this));

        // empty data from relayCompatible
        vm.prank(address(relayCompatible));
        relayCompatible.msgSenderBase();
        assertEq(sender, address(this));

        // <20 bytes data from this
        (bool success, bytes memory returnData) = address(relayCompatible).call(
            abi.encodeWithSelector(bytes4(relayCompatible.msgSenderBase.selector), bytes2(0x1337))
        );
        sender = abi.decode(returnData, (address));
        assertEq(sender, address(this));

        // <20 bytes data from relayCompatible
        vm.prank(address(relayCompatible));
        (success, returnData) = address(relayCompatible).call(
            abi.encodePacked(
                abi.encodeWithSelector(bytes4(relayCompatible.msgSenderBase.selector)),
                bytes2(0x1337)
            )
        );
        sender = abi.decode(returnData, (address));
        assertEq(sender, address(relayCompatible));

        // address data from this
        (success, returnData) = address(relayCompatible).call(
            abi.encodeWithSelector(bytes4(relayCompatible.msgSenderBase.selector), address(this))
        );
        sender = abi.decode(returnData, (address));
        assertEq(sender, address(this));

        // address data from relayCompatible
        vm.prank(address(relayCompatible));
        (success, returnData) = address(relayCompatible).call(
            abi.encodePacked(
                abi.encodeWithSelector(bytes4(relayCompatible.msgSenderBase.selector)),
                address(this)
            )
        );
        sender = abi.decode(returnData, (address));
        assertEq(sender, address(this));

        // >20 bytes with address from this
        (success, returnData) = address(relayCompatible).call(
            abi.encodePacked(
                abi.encodeWithSelector(bytes4(relayCompatible.msgSenderBase.selector)),
                bytes4(0x13371337),
                address(this)
            )
        );
        sender = abi.decode(returnData, (address));
        assertEq(sender, address(this));

        // >20 bytes with address from relayCompatible
        vm.prank(address(relayCompatible));
        (success, returnData) = address(relayCompatible).call(
            abi.encodePacked(
                abi.encodeWithSelector(bytes4(relayCompatible.msgSenderBase.selector)),
                bytes4(0x13371337),
                address(this)
            )
        );
        sender = abi.decode(returnData, (address));
        assertEq(sender, address(this));
    }

    function test_msgDataBase() public {
        // empty data from this
        bytes memory data = relayCompatible.msgDataBase();
        assertEq(data, abi.encodeWithSelector(relayCompatible.msgDataBase.selector));

        // empty data from relayCompatible
        vm.prank(address(relayCompatible));
        relayCompatible.msgDataBase();
        assertEq(data, abi.encodeWithSelector(relayCompatible.msgDataBase.selector));

        // <20 bytes data from this
        (bool success, bytes memory returnData) = address(relayCompatible).call(
            abi.encodeWithSelector(bytes4(relayCompatible.msgDataBase.selector), bytes2(0x1337))
        );
        data = abi.decode(returnData, (bytes));
        assertEq(
            data,
            abi.encodeWithSelector(bytes4(relayCompatible.msgDataBase.selector), bytes2(0x1337))
        );

        // <20 bytes data from relayCompatible
        vm.prank(address(relayCompatible));
        (success, returnData) = address(relayCompatible).call(
            abi.encodePacked(
                abi.encodePacked(bytes4(relayCompatible.msgDataBase.selector)),
                bytes2(0x1337)
            )
        );
        data = abi.decode(returnData, (bytes));
        assertEq(
            data,
            abi.encodePacked(bytes4(relayCompatible.msgDataBase.selector), bytes2(0x1337))
        );

        // // address data from this
        // (success, returnData) = address(relayCompatible).call(
        //     abi.encodeWithSelector(bytes4(relayCompatible.msgDataBase.selector), address(this))
        // );
        // data = abi.decode(returnData, (bytes));
        // assertEq(data, emptyCheckDataHash);

        // // address data from relayCompatible
        // vm.prank(address(relayCompatible));
        // (success, returnData) = address(relayCompatible).call(
        //     abi.encodePacked(
        //         abi.encodeWithSelector(bytes4(relayCompatible.msgDataBase.selector)),
        //         address(this)
        //     )
        // );
        // data = abi.decode(returnData, (address));
        // assertEq(data, address(this));

        // >20 bytes with address from this
        (success, returnData) = address(relayCompatible).call(
            abi.encodePacked(
                abi.encodeWithSelector(bytes4(relayCompatible.msgDataBase.selector)),
                bytes4(0x13371337),
                address(this)
            )
        );
        data = abi.decode(returnData, (bytes));
        assertEq(
            data,
            abi.encodePacked(
                abi.encodeWithSelector(bytes4(relayCompatible.msgDataBase.selector)),
                bytes4(0x13371337),
                address(this)
            )
        );

        // >20 bytes with address from relayCompatible
        vm.prank(address(relayCompatible));
        (success, returnData) = address(relayCompatible).call(
            abi.encodePacked(
                abi.encodeWithSelector(bytes4(relayCompatible.msgDataBase.selector)),
                bytes4(0x13371337),
                address(this)
            )
        );
        data = abi.decode(returnData, (bytes));
        assertEq(
            data,
            abi.encodePacked(bytes4(relayCompatible.msgDataBase.selector), bytes4(0x13371337))
        );
    }
}
