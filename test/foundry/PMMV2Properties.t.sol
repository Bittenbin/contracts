// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PMMV2Base} from "./PMMV2Base.t.sol";

contract PMMV2PropertiesTest is PMMV2Base {
    function testFuzzEuclidTriplesAreValidCoordinates(uint16 rawM, uint16 rawN, uint16 rawScale) public view {
        uint256 m = bound(rawM, 2, 1_000);
        uint256 n = bound(rawN, 1, m - 1);
        uint256 scale = bound(rawScale, 1, 100);

        uint256 x = scale * ((m * m) - (n * n));
        uint256 y = scale * (2 * m * n);

        assertTrue(pmm.isValidCoordinate(x, y));
        assertTrue(pmm.isValidCoordinate(y, x));
    }

    function testFuzzRejectsBoundedNonPythagoreanCoordinates(uint32 rawX, uint32 rawY) public view {
        uint256 x = bound(rawX, 1, 1_000_000);
        uint256 y = bound(rawY, 1, 1_000_000);
        uint256 sumSquares = (x * x) + (y * y);
        uint256 c = Math.sqrt(sumSquares);

        vm.assume(c * c != sumSquares);
        assertFalse(pmm.isValidCoordinate(x, y));
    }

    function testFuzzTvlAccountingForSingleRelocation(uint8 rawStart, uint8 rawEnd) public {
        uint256[10] memory coordinates = [
            uint256(3),
            uint256(4),
            uint256(5),
            uint256(12),
            uint256(8),
            uint256(15),
            uint256(7),
            uint256(24),
            uint256(20),
            uint256(21)
        ];
        uint256 startIndex = bound(rawStart, 0, 4);
        uint256 endIndex = bound(rawEnd, 0, 4);
        if (endIndex == startIndex) endIndex = (startIndex + 1) % 5;

        uint256 startX = coordinates[startIndex * 2];
        uint256 startY = coordinates[(startIndex * 2) + 1];
        uint256 endX = coordinates[endIndex * 2];
        uint256 endY = coordinates[(endIndex * 2) + 1];
        uint256 endC = Math.sqrt((endX * endX) + (endY * endY));

        bytes32 id = _create(alice, "fuzz-tvl-agent", startX, startY);
        _relocate(alice, id, startX, startY, endX, endY);

        assertEq(pmm.totalStakedValue(), endC);
    }

    function testFuzzEmissionNeverExceedsCap(uint16 rawYears) public {
        uint256 yearsElapsed = bound(rawYears, 1, 200);
        _create(alice, "bounded-emission-fuzz", 15, 20);

        vm.warp(block.timestamp + (yearsElapsed * YEAR));
        _claim(alice);

        assertLe(tbn.totalSupply(), pmm.MAX_TBN_EMISSION());
        assertEq(tbn.totalSupply(), pmm.totalTbnEmitted());
    }
}
