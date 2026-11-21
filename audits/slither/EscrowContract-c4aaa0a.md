# Slither results: EscrowContract.sol at c4aaa0a

This is the output of [Slither](https://github.com/crytic/slither) 0.11.4 (all 100 detectors,
solc 0.8.26) for [`src/EscrowContract.sol`](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol)
at commit `c4aaa0a`. That is the code deployed on Base at
[`0x55CD499D44Ac1536Fa461956Ac30EcdD7c9EAaa1`](https://basescan.org/address/0x55CD499D44Ac1536Fa461956Ac30EcdD7c9EAaa1),
the implementation every escrow is cloned from. Run on 21 November 2026.

**38 results: no High, 1 Medium, 10 Low, 27 Informational. None is a vulnerability.** What
each one means, and why it is safe, is in the
[README](https://github.com/conduit-ucpi/contracts#static-analysis-slither), with the
commands to reproduce this run.

**What is left out.** The run used `--exclude-dependencies`, so this covers our code only.
Slither also reports on the OpenZeppelin Contracts 5.4.0 library code the escrow imports
(`Math`, `SafeERC20`, `ECDSA`, `SignatureChecker` and others): 34 more results there, all in
OpenZeppelin's own files. That widely used library is audited and maintained separately, so
its results are not repeated here. To see them, run the README command without
`--exclude-dependencies`.

Everything below this line is Slither's output, unedited.

---

Summary
 - [incorrect-equality](#incorrect-equality) (1 results) (Medium)
 - [timestamp](#timestamp) (10 results) (Low)
 - [assembly](#assembly) (2 results) (Informational)
 - [pragma](#pragma) (1 results) (Informational)
 - [cyclomatic-complexity](#cyclomatic-complexity) (1 results) (Informational)
 - [low-level-calls](#low-level-calls) (1 results) (Informational)
 - [naming-convention](#naming-convention) (20 results) (Informational)
 - [unindexed-event-address](#unindexed-event-address) (2 results) (Informational)
## incorrect-equality
Impact: Medium
Confidence: High
 - [ ] ID-0
[EscrowContract.sweepToken(address)](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L997-L1014) uses a dangerous strict equality:
	- [balance == 0](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1009)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L997-L1014


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-1
[EscrowContract.canClaim()](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1793-L1795) uses timestamp for comparisons
	Dangerous comparisons:
	- [_state == 1 && EXPIRY_TIMESTAMP != 0 && block.timestamp >= EXPIRY_TIMESTAMP](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1794)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1793-L1795


 - [ ] ID-2
[EscrowContract.executeSigned(address,bytes,uint256,uint256,bytes)](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L625-L660) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp > deadline](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L632)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L625-L660


 - [ ] ID-3
[EscrowContract.claimFunds()](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1700-L1721) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < EXPIRY_TIMESTAMP](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1703)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1700-L1721


 - [ ] ID-4
[EscrowContract.transferRecipientFrom(address)](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1117-L1143) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp > recipientApprovalExpiry](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1120)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1117-L1143


 - [ ] ID-5
[EscrowContract.seatDefaultArbiter()](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1339-L1345) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp <= nominationDeadline](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1342)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1339-L1345


 - [ ] ID-6
[EscrowContract.evictArbiter()](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1402-L1418) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp <= lastArbiterActionAt + ARBITER_SILENCE_TIMEOUT](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1407)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1402-L1418


 - [ ] ID-7
[EscrowContract.raiseDispute()](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1482-L1506) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= EXPIRY_TIMESTAMP](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1485)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1482-L1506


 - [ ] ID-8
[EscrowContract.canDispute()](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1797-L1799) uses timestamp for comparisons
	Dangerous comparisons:
	- [_state == 1 && EXPIRY_TIMESTAMP != 0 && block.timestamp < EXPIRY_TIMESTAMP](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1798)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1797-L1799


 - [ ] ID-9
[EscrowContract.isExpired()](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1752-L1754) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= EXPIRY_TIMESTAMP](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1753)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1752-L1754


 - [ ] ID-10
[EscrowContract.checkAndActivate()](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L815-L860) uses timestamp for comparisons
	Dangerous comparisons:
	- [EXPIRY_TIMESTAMP != 0 && block.timestamp >= EXPIRY_TIMESTAMP](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L821)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L815-L860


## assembly
Impact: Informational
Confidence: High
 - [ ] ID-11
[EscrowContract._actor()](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L687-L692) uses assembly
	- [INLINE ASM](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L689-L691)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L687-L692


 - [ ] ID-12
[EscrowContract.executeSigned(address,bytes,uint256,uint256,bytes)](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L625-L660) uses assembly
	- [INLINE ASM](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L656-L658)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L625-L660


## pragma
Impact: Informational
Confidence: High
 - [ ] ID-13
6 different versions of Solidity are used:
	- Version constraint >=0.5.0 is used by:
		-[>=0.5.0](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/interfaces/IERC1271.sol#L4)
		-[>=0.5.0](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/interfaces/IERC7913.sol#L4)
	- Version constraint >=0.6.2 is used by:
		-[>=0.6.2](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol#L4)
	- Version constraint >=0.4.16 is used by:
		-[>=0.4.16](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol#L4)
		-[>=0.4.16](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol#L4)
		-[>=0.4.16](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
		-[>=0.4.16](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4)
	- Version constraint ^0.8.20 is used by:
		-[^0.8.20](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L4)
		-[^0.8.20](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/utils/Panic.sol#L4)
		-[^0.8.20](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol#L4)
		-[^0.8.20](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol#L4)
		-[^0.8.20](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L4)
		-[^0.8.20](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol#L5)
	- Version constraint ^0.8.24 is used by:
		-[^0.8.24](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/utils/Bytes.sol#L4)
		-[^0.8.24](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol#L4)
	- Version constraint 0.8.26 is used by:
		-[0.8.26](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L2)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/lib/openzeppelin-contracts/contracts/interfaces/IERC1271.sol#L4


## cyclomatic-complexity
Impact: Informational
Confidence: High
 - [ ] ID-14
[EscrowContract.initialize(address,address,address,address,uint256,uint256,uint256,address)](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L710-L778) has a high cyclomatic complexity (12).

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L710-L778


## low-level-calls
Impact: Informational
Confidence: High
 - [ ] ID-15
Low level call in [EscrowContract.executeSigned(address,bytes,uint256,uint256,bytes)](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L625-L660):
	- [(ok,answer) = address(this).call(abi.encodePacked(call,signer))](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L653)

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L625-L660


## naming-convention
Impact: Informational
Confidence: High
 - [ ] ID-16
Variable [EscrowContract.SELLER](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L310) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L310


 - [ ] ID-17
Variable [EscrowContract.AMOUNT](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L321) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L321


 - [ ] ID-18
Parameter [EscrowContract.initialize(address,address,address,address,uint256,uint256,uint256,address)._amount](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L715) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L715


 - [ ] ID-19
Variable [EscrowContract.BUYER](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L309) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L309


 - [ ] ID-20
Variable [EscrowContract.EXPIRY_TIMESTAMP](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L322) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L322


 - [ ] ID-21
Variable [EscrowContract.FACTORY](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L307) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L307


 - [ ] ID-22
Parameter [EscrowContract.initialize(address,address,address,address,uint256,uint256,uint256,address)._arbiter](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L714) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L714


 - [ ] ID-23
Variable [EscrowContract.GIT_COMMIT](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L408) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L408


 - [ ] ID-24
Parameter [EscrowContract.initialize(address,address,address,address,uint256,uint256,uint256,address)._creatorFee](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L717) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L717


 - [ ] ID-25
Parameter [EscrowContract.initialize(address,address,address,address,uint256,uint256,uint256,address)._tokenAddress](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L711) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L711


 - [ ] ID-26
Variable [EscrowContract.DEFAULT_ARBITER](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L402) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L402


 - [ ] ID-27
Parameter [EscrowContract.initialize(address,address,address,address,uint256,uint256,uint256,address)._expiryTimestamp](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L716) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L716


 - [ ] ID-28
Parameter [EscrowContract.submitResolutionVote(uint256)._buyerPercentage](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1562) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L1562


 - [ ] ID-29
Parameter [EscrowContract.initialize(address,address,address,address,uint256,uint256,uint256,address)._seller](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L713) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L713


 - [ ] ID-30
Variable [EscrowContract.CREATOR_FEE](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L324) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L324


 - [ ] ID-31
Parameter [EscrowContract.initialize(address,address,address,address,uint256,uint256,uint256,address)._feeSweeper](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L718) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L718


 - [ ] ID-32
Variable [EscrowContract.FEE_SWEEPER](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L318) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L318


 - [ ] ID-33
Variable [EscrowContract.ARBITER](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L317) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L317


 - [ ] ID-34
Parameter [EscrowContract.initialize(address,address,address,address,uint256,uint256,uint256,address)._buyer](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L712) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L712


 - [ ] ID-35
Parameter [EscrowContract.sweepToken(address)._token](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L997) is not in mixedCase

https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L997


## unindexed-event-address
Impact: Informational
Confidence: High
 - [ ] ID-36
Event [EscrowContract.FundsClaimed(address,uint256,uint256)](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L514) has address parameters but no indexed parameters

 - [ ] ID-37
Event [EscrowContract.FundsDeposited(address,uint256,uint256)](https://github.com/conduit-ucpi/contracts/blob/c4aaa0af5034337d5fcb0d9931735f85da3215ab/src/EscrowContract.sol#L503) has address parameters but no indexed parameters

