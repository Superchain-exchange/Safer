// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract MultiSigWallet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Transaction {
        uint256 id;
        address initiator;
        uint256 timestamp;
        address targetContract; // For token transfers, otherwise address(0) for native transfers
        uint256 amount;
        address receiver; // Address where funds should be sent
        bool executed;
        mapping(address => bool) approvals;
    }

    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public requiredApprovals;
    bool public initialized;
    uint256 public approvalTimeLimit; // Regular state variable for approval time limit (in seconds)

    Transaction[] public transactions;

    event TransactionInitiated(uint256 indexed id, address indexed initiator, uint256 amount, address receiver);
    event TransactionApproved(uint256 indexed id, address indexed approver);
    event TransactionExecuted(uint256 indexed id, address indexed executor);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event RequirementsSet(uint256 requiredApprovals, uint256 approvalTimeLimit);

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }

    modifier onlyInitialOwner() {
        require(msg.sender == owners[0], "Not the initial owner");
        _;
    }

    modifier notInitialized() {
        require(!initialized, "Already initialized");
        _;
    }

    constructor() {
        owners.push(msg.sender); // Deployer is the first owner
        isOwner[msg.sender] = true;
    }

    function initialize(uint256 _requiredApprovals, address[] calldata _additionalOwners, uint256 _approvalTimeLimit) external onlyInitialOwner notInitialized {
        require(_requiredApprovals > 0, "Required approvals must be greater than 0");
        require(_requiredApprovals <= _additionalOwners.length + 1, "Invalid required approvals");
        require(_approvalTimeLimit > 0, "Approval time limit must be greater than 0");

        for (uint256 i = 0; i < _additionalOwners.length; i++) {
            require(_additionalOwners[i] != address(0), "Invalid owner");
            require(!isOwner[_additionalOwners[i]], "Duplicate owner");
            isOwner[_additionalOwners[i]] = true;
            owners.push(_additionalOwners[i]);
        }

        requiredApprovals = _requiredApprovals;
        approvalTimeLimit = _approvalTimeLimit; // Set the approval time limit
        initialized = true;

        emit RequirementsSet(_requiredApprovals, _approvalTimeLimit);
    }

    function initiateRemoveNative(uint256 amount, address receiver) external onlyOwner {
        require(address(this).balance >= amount, "Insufficient native balance");

        uint256 id = transactions.length;
        transactions.push();
        Transaction storage newTransaction = transactions[id];
        newTransaction.id = id;
        newTransaction.initiator = msg.sender;
        newTransaction.timestamp = block.timestamp;
        newTransaction.targetContract = address(0);
        newTransaction.amount = amount;
        newTransaction.receiver = receiver;
        newTransaction.executed = false;

        emit TransactionInitiated(id, msg.sender, amount, receiver);
    }

    function initiateRemoveToken(address targetContract, uint256 amount, address receiver) external onlyOwner {
        require(targetContract != address(0), "Invalid token address");

        uint256 id = transactions.length;
        transactions.push();
        Transaction storage newTransaction = transactions[id];
        newTransaction.id = id;
        newTransaction.initiator = msg.sender;
        newTransaction.timestamp = block.timestamp;
        newTransaction.targetContract = targetContract;
        newTransaction.amount = amount;
        newTransaction.receiver = receiver;
        newTransaction.executed = false;

        emit TransactionInitiated(id, msg.sender, amount, receiver);
    }

    function approveTransaction(uint256 id) external onlyOwner {
        Transaction storage transaction = transactions[id];
        require(!transaction.executed, "Transaction already executed");
        require(block.timestamp <= transaction.timestamp + approvalTimeLimit, "Approval time limit exceeded");
        require(!transaction.approvals[msg.sender], "Already approved");

        transaction.approvals[msg.sender] = true;
        emit TransactionApproved(id, msg.sender);

        if (checkApprovals(id)) {
            executeTransaction(id);
        }
    }

    function checkApprovals(uint256 id) internal view returns (bool) {
        Transaction storage transaction = transactions[id];
        uint256 count = 0;
        for (uint256 i = 0; i < owners.length; i++) {
            if (transaction.approvals[owners[i]]) {
                count++;
            }
            if (count >= requiredApprovals) {
                return true;
            }
        }
        return false;
    }

    function executeTransaction(uint256 id) internal nonReentrant {
        Transaction storage transaction = transactions[id];
        require(!transaction.executed, "Transaction already executed");
        require(block.timestamp <= transaction.timestamp + approvalTimeLimit, "Approval time limit exceeded");

        transaction.executed = true;

        if (transaction.targetContract == address(0)) {
            // Native token transfer
            (bool success, ) = transaction.receiver.call{value: transaction.amount}("");
            require(success, "Native transfer failed");
        } else {
            // ERC20 token transfer
            IERC20 token = IERC20(transaction.targetContract);
            uint256 balanceBefore = token.balanceOf(transaction.receiver);
            token.safeTransfer(transaction.receiver, transaction.amount);
            uint256 balanceAfter = token.balanceOf(transaction.receiver);
            require(balanceAfter - balanceBefore == transaction.amount, "Token transfer failed");
        }

        emit TransactionExecuted(id, msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid new owner");
        require(!isOwner[newOwner], "Already an owner");

        isOwner[msg.sender] = false;
        isOwner[newOwner] = true;

        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == msg.sender) {
                owners[i] = newOwner;
                break;
            }
        }

        emit OwnershipTransferred(msg.sender, newOwner);
    }

    function getTransactionDetails(uint256 id) external view returns (
        uint256 transactionId,
        address initiator,
        uint256 timestamp,
        address targetContract,
        uint256 amount,
        address receiver,
        bool executed
    ) {
        require(id < transactions.length, "Invalid transaction ID");

        Transaction storage transaction = transactions[id];
        return (
            transaction.id,
            transaction.initiator,
            transaction.timestamp,
            transaction.targetContract,
            transaction.amount,
            transaction.receiver,
            transaction.executed
        );
    }

    receive() external payable {}
}
