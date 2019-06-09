pragma solidity ^0.4.24;

import "./openzeppelin/contracts/math/SafeMath.sol";
import "./openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./openzeppelin/contracts/ownership/Ownable.sol";
import "./EtherDollar.sol";
import "./Liquidator.sol";
import "./Finance.sol";


/**
 * @title Erc20Bank contract.
 */
contract Erc20Bank is Ownable {
    Finance internal finance;

    using SafeMath for uint256;

    uint256 public lastLoanId;
    uint256 public collateralPrice;
    uint256 public collateralRatio;
    uint256 public liquidationDuration;
    address public oraclesAddr;
    address public liquidatorAddr;
    address public etherDollarAddr;

    EtherDollar internal token;
    ERC20 internal collatralToken;

    Liquidator internal liquidator;

    uint256 constant internal PRECISION_POINT = 10 ** 3;
    uint256 constant internal MAX_LOAN = 10000 * 10 ** 18;
    uint256 constant internal COLLATERAL_MULTIPLIER = 2;

    uint256 constant internal COLLATERAL_TO_BASE_UNIT = 10 ** 18;

    address constant internal COLLATERAL_ADDRESS = 0x0;
    address constant internal FINANCE_ADDRESS = 0x0;

    enum Types {
        COLLATERAL_PRICE,
        COLLATERAL_RATIO,
        LIQUIDATION_DURATION
    }

    enum LoanStates {
    	UNDEFINED,
        ACTIVE,
        UNDER_LIQUIDATION,
        LIQUIDATED,
        SETTLED
    }

    struct Loan {
        address recipient;
        uint256 collateralAmount;
        uint256 amount;
        LoanStates state;
    }

    mapping(uint256 => Loan) public loans;

    event LoanGot(address indexed recipient, uint256 indexed loanId, uint256 amount, uint256 collateralAmount);
    event LoanSettled(address recipient, uint256 indexed loanId, uint256 collateralAmount, uint256 amount);
    event CollateralIncreased(address indexed recipient, uint256 indexed loanId, uint256 collateralAmount);
    event CollateralDecreased(address indexed recipient, uint256 indexed loanId, uint256 collateralAmount);
    event Discharged(uint256 amount);

    string private constant INVALID_AMOUNT = "INVALID_AMOUNT";
    string private constant INITIALIZED_BEFORE = "INITIALIZED_BEFORE";
    string private constant SUFFICIENT_COLLATERAL = "SUFFICIENT_COLLATERAL";
    string private constant INSUFFICIENT_COLLATERAL = "INSUFFICIENT_COLLATERAL";
    string private constant INSUFFICIENT_ALLOWANCE = "INSUFFICIENT_ALLOWANCE";
    string private constant ONLY_LOAN_OWNER = "ONLY_LOAN_OWNER";
    string private constant ONLY_LIQUIDATOR = "ONLY_LIQUIDATOR";
    string private constant ONLY_ORACLES = "ONLY_ORACLE";
    string private constant INVALID_LOAN_STATE = "INVALID_LOAN_STATE";
    string private constant EXCEEDED_MAX_LOAN = "EXCEEDED_MAX_LOAN";
    string private constant TOKENS_NOT_AVAILABLE = "TOKENS_NOT_AVAILABLE";

    string private constant FINANCE_MESSAGE = "DISCHARGE ERC20 BANK";

    constructor(address tokenAddr)
        public
    {
        token = EtherDollar(tokenAddr);
        etherDollarAddr = tokenAddr;
        collatralToken = ERC20(COLLATERAL_ADDRESS);
        collateralRatio = 1500; // = 1.5 * PRECISION_POINT
        liquidationDuration = 7200; // = 2 hours
        finance = Finance(FINANCE_ADDRESS);
    }

    /**
     * @notice discharge extera collateral.
     * @param amount The amount of collateral.
     */
    function discharge(uint256 amount)
        external
        onlyOwner
    {
        uint256 balance = collatralToken.balanceOf(address(this));
        require(amount <= balance, INVALID_AMOUNT);

        require(collatralToken.approve(address(finance), amount));
        finance.deposit(address(collatralToken), amount, FINANCE_MESSAGE);
        emit Discharged(amount);
    }

    /**
     * @notice Set Liquidator's address.
     * @param _liquidatorAddr The Liquidator's contract address.
     */
    function setLiquidator(address _liquidatorAddr)
        external
    {
        require(liquidatorAddr == address(0), INITIALIZED_BEFORE);

        liquidatorAddr = _liquidatorAddr;
        liquidator = Liquidator(_liquidatorAddr);
    }

    /**
     * @notice Set oracle's address.
     * @param _oraclesAddr The oracle's contract address.
     */
    function setOracle(address _oraclesAddr)
        external
    {
        require (oraclesAddr == address(0), INITIALIZED_BEFORE);

        oraclesAddr = _oraclesAddr;
    }

    /**
     * @notice Set important varibales by oracles.
     * @param _type Type of the variable.
     * @param value Amount of the variable.
     */
    function setVariable(uint8 _type, uint256 value)
        external
        onlyOracles
        throwIfEqualToZero(value)
    {
        if (uint8(Types.COLLATERAL_PRICE) == _type) {
            collateralPrice = value;
        } else if (uint8(Types.COLLATERAL_RATIO) == _type) {
            collateralRatio = value;
        } else if (uint8(Types.LIQUIDATION_DURATION) == _type) {
            liquidationDuration = value;
        }
    }

    /**
     * @notice Deposit ether to borrow ether dollar.
     * @param amount The amount of requsted loan in ether dollar.
     */
    function getLoan(uint256 amount)
        public
        payable
        throwIfEqualToZero(amount)
    {
        require (amount <= MAX_LOAN, EXCEEDED_MAX_LOAN);
        uint256 collateralAmount = collatralToken.allowance(msg.sender, address(this));
        require (collatralToken.transferFrom(msg.sender, address(this), collateralAmount));
        require (minCollateral(amount) <= collateralAmount, INSUFFICIENT_COLLATERAL);

        uint256 loanId = ++lastLoanId;
        loans[loanId].recipient = msg.sender;
        loans[loanId].collateralAmount = collateralAmount;
        loans[loanId].amount = amount;
        loans[loanId].state = LoanStates.ACTIVE;
        emit LoanGot(msg.sender, loanId, amount, collateralAmount);
        token.mint(msg.sender, amount);
    }

    /**
     * @notice Increase the loan's collateral.
     * @param loanId The loan id.
     */
    function increaseCollateral(uint256 loanId)
        external
        payable
        checkLoanStates(loanId, LoanStates.ACTIVE)
    {
        uint256 collateralAmount = collatralToken.allowance(msg.sender, address(this));
        require (collatralToken.transferFrom(msg.sender, address(this), collateralAmount));

        require(0 < collateralAmount, INVALID_AMOUNT);

        loans[loanId].collateralAmount = loans[loanId].collateralAmount.add(collateralAmount);
        emit CollateralIncreased(msg.sender, loanId, collateralAmount);
    }

    /**
     * @notice Pay back extera collateral.
     * @param loanId The loan id.
     * @param amount The amout of extera collateral.
     */
    function decreaseCollateral(uint256 loanId, uint256 amount)
        external
        throwIfEqualToZero(amount)
        onlyLoanOwner(loanId)
    {
        require(loans[loanId].state != LoanStates.UNDER_LIQUIDATION, INVALID_LOAN_STATE);

        require(minCollateral(loans[loanId].amount) <= loans[loanId].collateralAmount.sub(amount), INSUFFICIENT_COLLATERAL);

        loans[loanId].collateralAmount = loans[loanId].collateralAmount.sub(amount);
        emit CollateralDecreased(msg.sender, loanId, amount);
        require(collatralToken.transfer(loans[loanId].recipient, amount), TOKENS_NOT_AVAILABLE);
    }

    /**
     * @notice pay ether dollars back to settle the loan.
     * @param loanId The loan id.
     * @param amount The ether dollar amount payed back.
     */
    function settleLoan(uint256 loanId, uint256 amount)
        external
        checkLoanStates(loanId, LoanStates.ACTIVE)
        throwIfEqualToZero(amount)
    {
        require(amount <= loans[loanId].amount, INVALID_AMOUNT);

        require(token.transferFrom(msg.sender, address(this), amount), INSUFFICIENT_ALLOWANCE);

        uint256 payback = loans[loanId].collateralAmount.mul(amount).div(loans[loanId].amount);
        token.burn(amount);
        loans[loanId].collateralAmount = loans[loanId].collateralAmount.sub(payback);
        loans[loanId].amount = loans[loanId].amount.sub(amount);
        if (loans[loanId].amount == 0) {
            loans[loanId].state = LoanStates.SETTLED;
        }

        emit LoanSettled(loans[loanId].recipient, loanId, payback, amount);
        require(collatralToken.transfer(loans[loanId].recipient, payback), TOKENS_NOT_AVAILABLE);
    }

    /**
     * @notice Start liquidation process of the loan.
     * @param loanId The loan id.
     */
    function liquidate(uint256 loanId)
        external
        checkLoanStates(loanId, LoanStates.ACTIVE)
    {
        require (loans[loanId].collateralAmount < minCollateral(loans[loanId].amount), SUFFICIENT_COLLATERAL);

        loans[loanId].state = LoanStates.UNDER_LIQUIDATION;
        liquidator.startLiquidation(
            loanId,
            loans[loanId].collateralAmount,
            loans[loanId].amount,
            liquidationDuration
        );
    }

    /**
     * @dev pay a part of the collateral to the auction's winner.
     * @param loanId The loan id.
     * @param collateral The bid of winner.
     * @param buyer The winner account.
     */
    function liquidated(uint256 loanId, uint256 collateral, address buyer)
        external
        onlyLiquidator
        checkLoanStates(loanId, LoanStates.UNDER_LIQUIDATION)
        returns (bool)
    {
        require (collateral <= loans[loanId].collateralAmount, INVALID_AMOUNT);

        loans[loanId].collateralAmount = loans[loanId].collateralAmount.sub(collateral);
        loans[loanId].amount = 0;
        loans[loanId].state = LoanStates.LIQUIDATED;
        require(collatralToken.transfer(buyer, collateral), TOKENS_NOT_AVAILABLE);
        return true;
    }

    /**
     * @notice Minimum collateral in wei that is required for borrowing `amount`.
     * @param amount The amount of the loan.
     */
    function minCollateral(uint256 amount)
        public
        view
        returns (uint256)
    {
        uint256 min = amount.mul(collateralRatio).mul(COLLATERAL_TO_BASE_UNIT).div(PRECISION_POINT).div(collateralPrice);
        return min;
    }

    /**
     * @dev Throws if called by any account other than our Oracle.
     */
    modifier onlyOracles() {
        require(msg.sender == oraclesAddr, ONLY_ORACLES);
        _;
    }

    /**
     * @dev Throws if called by any account other than our Liquidator.
     */
    modifier onlyLiquidator() {
        require(msg.sender == liquidatorAddr, ONLY_LIQUIDATOR);
        _;
    }

    /**
     * @dev Throws if the number is equal to zero.
     * @param number The number to validate.
     */
    modifier throwIfEqualToZero(uint number) {
        require(number != 0, INVALID_AMOUNT);
        _;
    }

    /**
     * @dev Throws if called by any account other than the owner of the loan.
     * @param loanId The loan id.
     */
    modifier onlyLoanOwner(uint256 loanId) {
        require(loans[loanId].recipient == msg.sender, ONLY_LOAN_OWNER);
        _;
    }

    /**
     * @dev Throws if state is not equal to needState.
     * @param loanId The id of the loan.
     * @param needState The state which needed.
     */
    modifier checkLoanStates(uint256 loanId, LoanStates needState) {
        require(loans[loanId].state == needState, INVALID_LOAN_STATE);
        _;
    }
}
