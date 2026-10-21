// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MugiIMDVerifier} from "../../../src/game/MugiIMDVerifier.sol";

contract IMDPlanConsumerHarness {
    mapping(bytes32 => bool) public consumed;

    function approve(MugiIMDVerifier verifier, bytes32 hash, bytes calldata proof) external {
        require(!consumed[hash], "replay");
        require(verifier.verify(hash, proof, address(this)), "invalid approval");
        consumed[hash] = true;
    }
}

contract MugiIMDVerifierTest is Test {
    MugiIMDVerifier internal verifier;
    IMDPlanConsumerHarness internal consumer;
    uint256 constant KEY = 0xA11CE;
    bytes32 constant PLAN = keccak256("canonical plan");
    bytes32 constant REQUEST = keccak256("oracle request UUID");
    bytes32 constant QUESTION = keccak256("exact admitted question");
    uint64 constant NOW = 1_800_000_000;

    function setUp() public {
        vm.chainId(1);
        vm.roll(1000);
        vm.warp(NOW);
        consumer = new IMDPlanConsumerHarness();
        verifier = new MugiIMDVerifier(address(this), vm.addr(KEY), address(consumer), 5, 4, 900);
        verifier.pinRequest(REQUEST, QUESTION, PLAN, NOW + 1800);
    }

    function attestation() internal pure returns (MugiIMDVerifier.Attestation memory a) {
        a = MugiIMDVerifier.Attestation({
            requestId: REQUEST,
            chainId: 1,
            questionHash: QUESTION,
            answerType: 2,
            answer: abi.encode(PLAN),
            figure: 0,
            fromBlock: 900,
            toBlock: 990,
            blockHash: bytes32(uint256(7)),
            panelJobId: bytes32(uint256(9)),
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: NOW,
            expiresAt: NOW + 600
        });
    }

    function proof(MugiIMDVerifier.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, verifier.attestationDigest(a));
        return abi.encode(a, abi.encodePacked(r, s, v));
    }

    function accepts(MugiIMDVerifier.Attestation memory a) internal view returns (bool) {
        return verifier.verify(PLAN, proof(a), address(consumer));
    }

    function testValidPinnedPlanAndConsumerReplayGuard() public {
        bytes memory p = proof(attestation());
        assertTrue(verifier.verify(PLAN, p, address(consumer)));
        consumer.approve(verifier, PLAN, p);
        assertTrue(consumer.consumed(PLAN));
        vm.expectRevert("replay");
        consumer.approve(verifier, PLAN, p);
    }

    function testSignatureVerificationFitsCallbackStipend() public {
        bytes memory input = abi.encodeCall(verifier.verify, (PLAN, proof(attestation()), address(consumer)));
        (bool ok, bytes memory output) = address(verifier).staticcall{gas: 200_000}(input);
        assertTrue(ok);
        assertTrue(abi.decode(output, (bool)));
    }

    function testWrongConsumerAndDomainAreRejected() public {
        bytes memory p = proof(attestation());
        assertFalse(verifier.verify(PLAN, p, address(0xBAD)));
        MugiIMDVerifier other = new MugiIMDVerifier(address(this), vm.addr(KEY), address(0xBAD), 5, 4, 900);
        other.pinRequest(REQUEST, QUESTION, PLAN, NOW + 1800);
        assertFalse(other.verify(PLAN, p, address(0xBAD)));
    }

    function testCrossChainReplayRejected() public {
        bytes memory p = proof(attestation());
        vm.chainId(11155111);
        assertFalse(verifier.verify(PLAN, p, address(consumer)));
    }

    function testUnpinnedAndWrongQuestionOrAnswerRejected() public view {
        MugiIMDVerifier.Attestation memory a = attestation();
        a.requestId = bytes32(uint256(91));
        assertFalse(accepts(a));
        a = attestation();
        a.questionHash = bytes32(uint256(92));
        assertFalse(accepts(a));
        a = attestation();
        a.answer = abi.encode(bytes32(uint256(93)));
        assertFalse(accepts(a));
        a = attestation();
        a.answerType = 3;
        assertFalse(accepts(a));
    }

    function testPanelPolicyRejectsMinorityAndImpossibleCounts() public view {
        MugiIMDVerifier.Attestation memory a = attestation();
        a.agreed = 3;
        assertFalse(accepts(a));
        a = attestation();
        a.panelSize = 4;
        a.agreed = 4;
        assertFalse(accepts(a));
        a = attestation();
        a.quorum = 3;
        assertFalse(accepts(a));
        a = attestation();
        a.agreed = 6;
        assertFalse(accepts(a));
        a = attestation();
        a.quorum = 6;
        a.agreed = 6;
        assertFalse(accepts(a));
    }

    function testExpiryFutureIssueAndStaleAnswerRejected() public {
        MugiIMDVerifier.Attestation memory a = attestation();
        a.expiresAt = NOW - 1;
        assertFalse(accepts(a));
        a = attestation();
        a.issuedAt = NOW + 1;
        assertFalse(accepts(a));
        a = attestation();
        a.issuedAt = NOW - 901;
        assertFalse(accepts(a));
        bytes memory p = proof(attestation());
        vm.warp(NOW + 1801);
        assertFalse(verifier.verify(PLAN, p, address(consumer)));
    }

    function testMalformedAndFutureBlockMetadataRejected() public view {
        MugiIMDVerifier.Attestation memory a = attestation();
        a.fromBlock = 991;
        assertFalse(accepts(a));
        a = attestation();
        a.toBlock = 1001;
        assertFalse(accepts(a));
        a = attestation();
        a.panelJobId = 0;
        assertFalse(accepts(a));
        a = attestation();
        a.answer = hex"01";
        assertFalse(accepts(a));
    }

    function testTamperedSignatureRejected() public view {
        MugiIMDVerifier.Attestation memory a = attestation();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, verifier.attestationDigest(a));
        a.figure = 99;
        assertFalse(verifier.verify(PLAN, abi.encode(a, abi.encodePacked(r, s, v)), address(consumer)));
    }

    function testRevocationCannotBeRepinned() public {
        bytes memory p = proof(attestation());
        verifier.revokeRequest(REQUEST);
        assertFalse(verifier.verify(PLAN, p, address(consumer)));
        vm.expectRevert(MugiIMDVerifier.RequestAlreadyPinned.selector);
        verifier.pinRequest(REQUEST, QUESTION, PLAN, NOW + 1800);
    }

    function testOnlyOwnerCanPin() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        verifier.pinRequest(bytes32(uint256(2)), QUESTION, PLAN, NOW + 1800);
        vm.stopPrank();
    }

    function testOwnerCannotRotateSignerOrWeakenEvidencePolicy() public {
        bytes memory originalProof = proof(attestation());
        (bool changed,) = address(verifier).call(abi.encodeWithSignature(
            "setPolicy(address,uint16,uint16,uint64)", vm.addr(0xBAD), uint16(2), uint16(2), uint64(100 days)
        ));
        assertFalse(changed);
        MugiIMDVerifier.Attestation memory a = attestation();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, verifier.attestationDigest(a));
        assertFalse(verifier.verify(PLAN, abi.encode(a, abi.encodePacked(r, s, v)), address(consumer)));
        assertTrue(verifier.verify(PLAN, originalProof, address(consumer)));
        assertEq(verifier.minimumPanelSize(), 5);
        assertEq(verifier.minimumQuorum(), 4);
        assertEq(verifier.maximumAge(), 900);
    }

    // Independent IMD SDK vector from the canonical reference, not signed by this test.
    // The vector asks about chain 1 but signs for a Sepolia consumer; digest calculation
    // must preserve that distinction even though Mugi's trading policy requires same-chain data.
    function testCanonicalIMDProtocolDigestAndSignatureVector() public {
        vm.chainId(11155111);
        address signer = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        MugiIMDVerifier referenceVerifier =
            new MugiIMDVerifier(address(this), signer, 0x0000000000000000000000000000000000002748, 5, 4, 900);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        MugiIMDVerifier.Attestation memory a = MugiIMDVerifier.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
        bytes32 expected = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
        bytes memory signature =
            hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
        assertEq(referenceVerifier.attestationDigest(a), expected);
        assertEq(ECDSA.recover(expected, signature), signer);
    }
}
