## DATA MATCHMAKERS (Team-8)

## Kendrix Entity Resolution — Solution Summary

### Objective

The solution addresses the challenge of identifying customer records that represent the same real-world entity across two banking systems: **Totara Mutual** and **Harbourside Bank**. The objective is to transform inconsistent source records into a standardised customer view, identify potential matches using multiple identity attributes, assign a confidence score, and evaluate matching performance against a known answer set.

### 1. Data Cleaning and Standardisation

The `clean.sql` pipeline prepares customer data from both source systems and creates standardised customer tables:

* `CLEAN.TOTARA_CUSTOMERS`
* `CLEAN.HARBOURSIDE_CUSTOMERS`

Source-specific fields are transformed into a common structure. Names and email addresses are standardised, Tax/IRD identifiers are normalised to numeric values, phone numbers are cleaned, NZBN values are standardised, and multiple address fields are consolidated into a common address representation.

This creates a consistent foundation for comparing records that originally have different structures and formatting conventions.

### 2. Data Quality and Candidate Generation

The pipeline profiles the availability of key matching attributes by comparing records across Tax ID, email, phone number and date of birth.

Potential customer pairs are then generated in `CLEAN.CANDIDATE_PAIRS`. A pair becomes a candidate when at least one strong identifying attribute—Tax ID, phone number or date of birth—is shared across the two source systems.

This candidate-generation stage reduces the number of comparisons required while retaining records that have evidence of potentially representing the same customer.

### 3. Feature Engineering

The `fetureEngineer.sql` pipeline converts each candidate pair into a set of matching features stored in:

`CLEAN.CUSTOMER_MATCH_FEATURES`

The solution combines:

* Exact Tax ID matching
* Exact phone matching
* Exact date-of-birth matching
* Jaro-Winkler name similarity
* Jaro-Winkler address similarity

This allows the system to consider both exact identifiers and approximate similarities rather than relying on a single field.

### 4. Confidence Scoring and Matching

The features are combined into a weighted match score stored in:

`CLEAN.CUSTOMER_MATCH_SCORE`

The current scoring model assigns greater weight to strong identity evidence:

| Feature             | Weight |
| ------------------- | -----: |
| Tax ID match        |     60 |
| Phone match         |     15 |
| Date of birth match |     10 |
| Name similarity     |     10 |
| Address similarity  |      5 |

The resulting score provides an interpretable measure of matching confidence. The current baseline classifies pairs with a score of **80 or above as `MATCH`** and lower-scoring pairs as `NO_MATCH`.

The final decisions are stored in:

`CLEAN.CUSTOMER_MATCH_RESULTS`

### 5. Model Evaluation

The `finalResult.sql` pipeline evaluates the matching decisions against the known answer key:

`PUBLIC.BANK_MERGER_ANSWER_KEY`

The evaluation identifies:

* True Positives — correctly identified matches
* False Positives — incorrect matches
* False Negatives — missed matches
* True Negatives — correctly rejected pairs

From these outcomes, the solution calculates:

* Accuracy
* Precision
* Recall
* F1 Score

This provides an objective basis for assessing and tuning the matching threshold and feature weights rather than relying only on the number of records classified as matches.

### 6. Current Baseline

The current pipeline generated 121 candidate pairs. Using the initial score threshold of 80, the baseline produced:

55 MATCH
66 NO_MATCH
With threshold = 30, the accuracy is 85.8%

The next optimisation step is to evaluate this baseline against the answer key and test alternative thresholds and matching rules. This allows the team to identify a configuration that provides stronger matching performance while maintaining explainability and auditability.

The overall design is intentionally transparent and modular so that each matching decision can be traced back to the underlying customer attributes and scoring evidence.

