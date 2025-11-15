# Contributing to Conduit UCPI Contracts

Thank you for your interest in contributing to Conduit UCPI's smart contracts! This document provides guidelines for contributing to this project.

## Code of Conduct

By participating in this project, you agree to maintain a respectful and collaborative environment for all contributors.

## How to Contribute

### Reporting Bugs

1. Check if the bug has already been reported in [Issues](https://github.com/conduit-ucpi/contracts/issues)
2. If not, create a new issue with:
   - Clear title and description
   - Steps to reproduce
   - Expected vs actual behavior
   - Foundry version and network details
   - Relevant logs or error messages

### Suggesting Enhancements

1. Check existing [Issues](https://github.com/conduit-ucpi/contracts/issues) for similar suggestions
2. Create a new issue describing:
   - The enhancement and its benefits
   - Potential implementation approach
   - Any security implications

### Pull Requests

1. **Fork the repository** and create a new branch from `main`
2. **Make your changes** following our coding standards
3. **Add tests** for any new functionality
4. **Run the test suite**: `forge test -vvv`
5. **Update documentation** if needed
6. **Submit a pull request** with a clear description

## Development Workflow

### Setup

```bash
# Clone your fork
git clone https://github.com/conduit-ucpi/contracts.git
cd contracts

# Install dependencies
forge install

# Create .env file
cp .env.example .env
```

### Testing

```bash
# Run all tests
forge test -vvv

# Run specific test
forge test --match-contract EscrowContractTest -vvv

# Generate gas report
forge test --gas-report

# Coverage report
forge coverage
```

### Before Submitting

- [ ] All tests pass
- [ ] Code follows Solidity style guide
- [ ] New tests added for new functionality
- [ ] Documentation updated
- [ ] No compiler warnings
- [ ] Gas optimizations considered

## Coding Standards

### Solidity Style Guide

- Follow the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- Use NatSpec comments for all public functions
- Keep functions focused and concise
- Prefer explicit over implicit

### Security Best Practices

- **Never** introduce reentrancy vulnerabilities
- Validate all inputs
- Use OpenZeppelin contracts when possible
- Follow checks-effects-interactions pattern
- Consider gas optimization vs readability tradeoffs

### Git Commit Messages

- Use present tense ("Add feature" not "Added feature")
- Use imperative mood ("Move cursor to..." not "Moves cursor to...")
- First line: brief summary (50 chars or less)
- Additional details in subsequent paragraphs if needed
- Reference issues and pull requests when relevant

Example:
```
Add percentage-based dispute resolution

- Implement splitFunds function in EscrowContract
- Add admin resolution capability in Factory
- Include comprehensive test coverage

Closes #123
```

## Smart Contract Security

### Critical Changes

Changes to core contract logic require:
1. Thorough security review
2. Comprehensive test coverage
3. Gas optimization analysis
4. Multiple reviewer approvals

### Security Review Checklist

- [ ] Reentrancy protection verified
- [ ] Access controls properly implemented
- [ ] Integer overflow/underflow impossible (Solidity 0.8+)
- [ ] External calls handled safely
- [ ] Events emitted for all state changes
- [ ] Gas limits considered for loops
- [ ] Fallback/receive functions reviewed

## Review Process

1. Automated tests must pass
2. Code review by at least one maintainer
3. Security review for contract changes
4. Documentation review
5. Final approval and merge

## Questions?

Feel free to open an issue with the `question` label or reach out to the maintainers.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
