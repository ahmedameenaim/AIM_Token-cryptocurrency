pragma solidity ^0.4.24;

import "../node_modules/openzeppelin-solidity/contracts/math/SafeMath.sol";
import "../node_modules/openzeppelin-solidity/contracts/ownership/Ownable.sol";

contract LockableToken is Ownable {
    function totalSupply() public view returns (uint256);
    function balanceOf(address who) public view returns (uint256);
    function transfer(address to, uint256 value) public returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    function allowance(address owner, address spender) public view returns (uint256);
    function transferFrom(address from, address to, uint256 value) public returns (bool);
    function approve(address spender, uint256 value) public returns (bool);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SubmissionFeeChanged(uint256 newFee);
    event SubmissionCreated(uint256 index, bytes content, bool image, address submitter);
    event SubmissionDeleted(uint256 index, bytes content, bool image, address submitter);
    function approveAndCall(address _spender, uint256 _value, bytes _data) public payable returns (bool);
    function transferAndCall(address _to, uint256 _value, bytes _data) public payable returns (bool);
    function transferFromAndCall(address _from, address _to, uint256 _value, bytes _data) public payable returns (bool);

    function increaseLockedAmount(address _owner, uint256 _amount) public returns (uint256);
    function decreaseLockedAmount(address _owner, uint256 _amount) public returns (uint256);
    function getLockedAmount(address _owner) view public returns (uint256);
    function getUnlockedAmount(address _owner) view public returns (uint256);
    mapping (bytes32 => Submission) public submissions;
    mapping (address => uint256) public deletions;

    bytes32[] public submissionIndex;

    struct Submission {
    bytes content;
    bool image;
    uint256 index;
    address submitter;
    bool exists;
}

    struct Proposal {
    string description;
    bool executed;
    int256 currentResult;
    uint8 typeFlag; // 1 = delete
    bytes32 target; // ID of the proposal target. I.e. flag 1, target XXXXXX (hash) means proposal to delete submissions[hash]
    uint256 creationDate;
    uint256 deadline;
    mapping (address => bool) voters;
    Vote[] votes;
    address submitter;
}

Proposal[] public proposals;
uint256 proposalCount = 0;
event ProposalAdded(uint256 id, uint8 typeFlag, bytes32 hash, string description, address submitter);
event ProposalExecuted(uint256 id);
event Voted(address voter, bool vote, uint256 power, string justification);

struct Vote {
    bool inSupport;
    address voter;
    string justification;
    uint256 power;
}

modifier tokenHoldersOnly() {
    require(token.balanceOf(msg.sender) >= 10**token.decimals());
    _;
}

function vote(uint256 _proposalId, bool _vote, string _description, uint256 _votePower) tokenHoldersOnly public returns (int256) {

    require(_votePower > 0, "At least some power must be given to the vote.");
    require(uint256(_votePower) <= token.balanceOf(msg.sender), "Voter must have enough tokens to cover the power cost.");

    Proposal storage p = proposals[_proposalId];

    require(p.executed == false, "Proposal must not have been executed already.");
    require(p.deadline > now, "Proposal must not have expired.");
    require(p.voters[msg.sender] == false, "User must not have already voted.");

    uint256 voteid = p.votes.length++;
    Vote storage pvote = p.votes[voteid];
    pvote.inSupport = _vote;
    pvote.justification = _description;
    pvote.voter = msg.sender;
    pvote.power = _votePower;

    p.voters[msg.sender] = true;

    p.currentResult = (_vote) ? p.currentResult + int256(_votePower) : p.currentResult - int256(_votePower);
    token.increaseLockedAmount(msg.sender, _votePower);

    emit Voted(msg.sender, _vote, _votePower, _description);
    return p.currentResult;
}

modifier memberOnly() {
    require(whitelist[msg.sender]);
    require(!blacklist[msg.sender]);
    _;
}

function executeProposal(uint256 _id) public {
    Proposal storage p = proposals[_id];
    require(now >= p.deadline && !p.executed);

    if (p.typeFlag == 1 && p.currentResult > 0) {
        assert(deleteSubmission(p.target));
    }

    uint256 len = p.votes.length;
    for (uint i = 0; i < len; i++) {
        token.decreaseLockedAmount(p.votes[i].voter, p.votes[i].power);
    }

    p.executed = true;
    emit ProposalExecuted(_id);
}

function proposeDeletion(bytes32 _hash, string _description) memberOnly public {

    require(submissionExists(_hash), "Submission must exist to be deletable");

    uint256 proposalId = proposals.length++;
    Proposal storage p = proposals[proposalId];
    p.description = _description;
    p.executed = false;
    p.creationDate = now;
    p.submitter = msg.sender;
    p.typeFlag = 1;
    p.target = _hash;

    p.deadline = now + 2 days;

    emit ProposalAdded(proposalId, 1, _hash, _description, msg.sender);
    proposalCount = proposalId + 1;
}

function proposeDeletionUrgent(bytes32 _hash, string _description) onlyOwner public {

    require(submissionExists(_hash), "Submission must exist to be deletable");

    uint256 proposalId = proposals.length++;
    Proposal storage p = proposals[proposalId];
    p.description = _description;
    p.executed = false;
    p.creationDate = now;
    p.submitter = msg.sender;
    p.typeFlag = 1;
    p.target = _hash;

    p.deadline = now + 12 hours;

    emit ProposalAdded(proposalId, 1, _hash, _description, msg.sender);
    proposalCount = proposalId + 1;
}    

function proposeDeletionUrgentImage(bytes32 _hash, string _description) onlyOwner public {

    require(submissions[_hash].image == true, "Submission must be existing image");

    uint256 proposalId = proposals.length++;
    Proposal storage p = proposals[proposalId];
    p.description = _description;
    p.executed = false;
    p.creationDate = now;
    p.submitter = msg.sender;
    p.typeFlag = 1;
    p.target = _hash;

    p.deadline = now + 4 hours;

    emit ProposalAdded(proposalId, 1, _hash, _description, msg.sender);
    proposalCount = proposalId + 1;
}
    function createSubmission(bytes _content, bool _image) storyActive external payable {

    require(token.balanceOf(msg.sender) >= 10**token.decimals());
    require(whitelist[msg.sender], "Must be whitelisted");
    require(!blacklist[msg.sender], "Must not be blacklisted");

    uint256 fee = calculateSubmissionFee();
    require(msg.value >= fee, "Fee for submitting an entry must be sufficient.");

    bytes32 hash = keccak256(abi.encodePacked(_content, block.number));
    require(!submissionExists(hash), "Submission must not already exist in same block!");

    if (_image) {
        require(imageGap >= imageGapMin, "Image can only be submitted if more than {imageGapMin} texts precede it.");
        imageGap = 0;
    } else {
        imageGap += 1;
    }

    submissions[hash] = Submission(
        _content,
        _image,
        submissionIndex.push(hash),
        msg.sender,
        true
    );

    emit SubmissionCreated(
        submissions[hash].index,
        submissions[hash].content,
        submissions[hash].image,
        submissions[hash].submitter
    );

    nonDeletedSubmissions += 1;
    withdrawableByOwner += fee.div(daofee);
}

  function deleteSubmission(bytes32 hash) internal returns (bool) {
    require(submissionExists(hash), "Submission must exist to be deletable.");
    Submission storage sub = submissions[hash];

    sub.exists = false;
    deletions[submissions[hash].submitter] += 1;
    if (deletions[submissions[hash].submitter] >= 5) {
        blacklistAddress(submissions[hash].submitter);
    }

    emit SubmissionDeleted(
        sub.index,
        sub.content,
        sub.image,
        sub.submitter
    );

    nonDeletedSubmissions -= 1;
    return true;
}

function blacklistAddress(address _offender) internal {
    require(blacklist[_offender] == false, "Can't blacklist a blacklisted user :/");
    blacklist[_offender] == true;
    token.increaseLockedAmount(_offender, token.getUnlockedAmount(_offender));
    emit Blacklisted(_offender, true);
}

function unblacklistMe() payable public {
    unblacklistAddress(msg.sender);
}

function notVoting(address _voter) internal view returns (bool) {
    for (uint256 i = 0; i < proposalCount; i++) {
        if (proposals[i].executed == false && proposals[i].voters[_voter] == true) {
            return false;
        }
    }
    return true;
}

bool public active = true;
event StoryEnded();

modifier storyActive() {
    require(active == true);
    _;
}

function withdrawLeftoverTokens() external onlyOwner {
    require(active == false);
    token.transfer(msg.sender, token.balanceOf(address(this)));
    token.transferOwnership(msg.sender);
}

function unlockMyTokens() external {
    require(active == false);
    require(token.getLockedAmount(msg.sender) > 0);

    token.decreaseLockedAmount(msg.sender, token.getLockedAmount(msg.sender));
}

function withdrawDividend() memberOnly external {
    require(active == false);
    uint256 owed = address(this).balance.div(whitelistedNumber);
    msg.sender.transfer(owed);
    whitelist[msg.sender] = false;
    whitelistedNumber--;
}

function endStory() storyActive external {
    withdrawToOwner();
    active = false;
    emit StoryEnded();
}

function unblacklistAddress(address _offender) payable public {
    require(msg.value >= 0.05 ether, "Unblacklisting fee");
    require(blacklist[_offender] == true, "Can't unblacklist a non-blacklisted user :/");
    require(notVoting(_offender), "Offender must not be involved in a vote.");
    withdrawableByOwner = withdrawableByOwner.add(msg.value);
    blacklist[_offender] = false;
    token.decreaseLockedAmount(_offender, token.balanceOf(_offender));
    emit Blacklisted(_offender, false);
}

    LockableToken public token;

    uint256 public tokenToWeiRatio = 10000;

    uint256 public submissionZeroFee = 0.0001 ether;
    uint256 public nonDeletedSubmissions = 0;

   function calculateSubmissionFee() view internal returns (uint256) {
    return submissionZeroFee * nonDeletedSubmissions;
   }

   function buyTokensThrow(address _buyer, uint256 _wei) external {

    require(whitelist[_buyer], "Candidate must be whitelisted.");
    require(!blacklist[_buyer], "Candidate must not be blacklisted.");

    uint256 tokens = _wei * tokenToWeiRatio;
    require(daoTokenBalance() >= tokens, "DAO must have enough tokens for sale");
    token.transfer(_buyer, tokens);
  }

   function buyTokensInternal(address _buyer, uint256 _wei) internal {
    require(!blacklist[_buyer], "Candidate must not be blacklisted.");
    uint256 tokens = _wei * tokenToWeiRatio;
    if (daoTokenBalance() < tokens) {
        msg.sender.transfer(_wei);
    } else {
        token.transfer(_buyer, tokens);
    }
}

function lowerSubmissionFee(uint256 _fee) onlyOwner external {
    require(_fee < submissionZeroFee, "New fee must be lower than old fee.");
    submissionZeroFee = _fee;
    emit SubmissionFeeChanged(_fee);
}

    constructor(address _token) public {
    require(_token != address(0), "Token address cannot be null-address");
    token = LockableToken(_token);

    event TokenAddressChange(address token);

 function daoTokenBalance() public view returns (uint256) {
    return token.balanceOf(address(this));
}

 function changeTokenAddress(address _token) onlyOwner public {
    require(_token != address(0), "Token address cannot be null-address");
    token = LockableToken(_token);
    emit TokenAddressChange(_token);
}
}
}

contract StroyDao is Ownable {
    using SafeMath for uint256;

    mapping(address => bool) whitelist;
    mapping(address => bool) blacklist;

    uint256 public whitelistedNumber = 0;
    uint256 public daofee = 100; // hundredths of a percent, i.e. 100 is 1%
    uint256 public whitelistfee = 10000000000000000; // in Wei, this is 0.01 ether
    uint256 public durationDays = 21; // duration of story's chapter in days
    uint256 public durationSubmissions = 1000; // duration of story's chapter in entries
    
    event Whitelisted(address addr , bool status);
    event Blacklist(address addr , bool status);
    event SubmissionCommissionChanged(uint256 newFee);
    event WhitelistFeeChanged(uint256 newFee);

    function changedaofee(uint256 _fee) onlyOwner external  {
        require(_fee < daofee , "new fee must be lower than old fee");
        daofee = _fee;
        emit SubmissionCommissionChanged(_fee);
    }

    function changewhitelistfee(uint256 _fee) onlyOwner external {
        require(_fee < whitelistfee, "New fee must be lower than old fee.");
        whitelistfee = _fee;
        emit WhitelistFeeChanged(_fee);
    }

    function lowerSubmissionFee(uint256 _fee) onlyOwner external {
        require(_fee < submissionZeroFee, "New fee must be lower than old fee.");
        submissionZeroFee = _fee;
        emit SubmissionFeeChanged(_fee);
    }

     function changeDurationDays(uint256 _days) onlyOwner external {
        require(_days >= 1);
        durationDays = _days;
    }

    function changeDurationSubmissions(uint256 _subs) onlyOwner external {
        require(_subs > 99);
        durationSubmissions = _subs;
    }

    function whitelistAddress(address _add) public payable {
    require(!whitelist[_add], "Candidate must not be whitelisted.");
    require(!blacklist[_add], "Candidate must not be blacklisted.");
    require(msg.value >= whitelistfee, "Sender must send enough ether to cover the whitelisting fee.");

    whitelist[_add] = true;
    whitelistedNumber++;
    emit Whitelisted(_add, true);

    if (msg.value > whitelistfee) {
        // buyTokens(_add, msg.value.sub(whitelistfee));
    }
}

function withdrawEverythingPostDeadline() external onlyOwner {
    require(active == false);
    require(now > deadline + 14 days);
    owner.transfer(address(this).balance);
}
}


}