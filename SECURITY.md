# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

The security of our smart contracts is our top priority. If you discover a security vulnerability, please follow these steps:

### 1. Private Disclosure

Send a detailed report to: **security@conduit-ucpi.com** (or create a [private security advisory](https://github.com/conduit-ucpi/contracts/security/advisories/new))

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)
- Your contact information for follow-up

### 2. Response Timeline

- **Initial Response**: Within 48 hours of report
- **Status Update**: Within 7 days with assessment
- **Fix Timeline**: Depends on severity (critical issues prioritized)
- **Public Disclosure**: Coordinated with reporter after fix deployment

### 3. Severity Assessment

We use the following severity levels:

**Critical**: Immediate threat to user funds or contract integrity
- Response: Immediate action, potential emergency deployment
- Bounty: Up to $10,000 (if bug bounty program active)

**High**: Significant risk requiring prompt attention
- Response: Within 7 days
- Bounty: Up to $5,000

**Medium**: Notable issue with workarounds available
- Response: Within 30 days
- Bounty: Up to $1,000

**Low**: Minor issues with minimal impact
- Response: Best effort
- Bounty: Recognition in security acknowledgments

## Security Measures

### Smart Contract Security

- **OpenZeppelin Contracts**: Using battle-tested implementations
- **Reentrancy Protection**: All state-changing functions protected
- **Access Controls**: Role-based permissions implemented
- **Immutability**: Critical parameters are immutable
- **Comprehensive Testing**: Unit and integration test coverage
- **No Upgrade Mechanisms**: Security by design (no proxy patterns)

### Development Practices

- Code reviews required for all changes
- Automated testing in CI/CD
- Solidity compiler warnings treated as errors
- Regular dependency updates
- Security-focused design patterns

### Deployment Security

- Multi-signature wallet for factory ownership (recommended)
- Contract verification on block explorers
- Gradual rollout for major updates
- Emergency pause mechanisms where appropriate

## Known Limitations

- Reliance on accurate time (block.timestamp)
- Dependency on USDC contract functionality
- Gas payer address trusted for dispute resolution

## Audit Status

- **Last Audit**: [Date - if applicable]
- **Auditor**: [Firm name - if applicable]
- **Report**: [Link to audit report - if applicable]

## Contact

- Security Email: security@conduit-ucpi.com
- GitHub Security Advisories: [GitHub Security Advisories](https://github.com/conduit-ucpi/contracts/security/advisories)

## Recognition

We appreciate the security research community's efforts to keep our contracts secure. Security researchers who responsibly disclose vulnerabilities will be:

- Acknowledged in our security hall of fame (with permission)
- Considered for bug bounties (if program is active)
- Credited in release notes for fixed issues

Thank you for helping keep Conduit UCPI secure!
