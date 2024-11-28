;; title: Identity Management Smart Contract
;; summary: A smart contract for managing identities, credentials, and reputation scores on the blockchain.
;; description: 
;; This smart contract provides functionalities for registering identities, issuing and revoking credentials, 
;; updating reputation scores, and initiating recovery mechanisms. It includes various error codes, constants 
;; for validation, data maps for storing identities, credentials, and zero-knowledge proofs, and state variables 
;; for managing the contract's state. The contract also defines utility functions for validating inputs, 
;; administrative functions for setting the admin, and public functions for managing identities, credentials, 
;; and reputation scores.

;; constants
;;

;; Error Codes
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-ALREADY-REGISTERED (err u1001))
(define-constant ERR-NOT-REGISTERED (err u1002))
(define-constant ERR-INVALID-PROOF (err u1003))
(define-constant ERR-INVALID-CREDENTIAL (err u1004))
(define-constant ERR-EXPIRED-CREDENTIAL (err u1005))
(define-constant ERR-REVOKED-CREDENTIAL (err u1006))
(define-constant ERR-INVALID-SCORE (err u1007))
(define-constant ERR-INVALID-INPUT (err u1008))
(define-constant ERR-INVALID-EXPIRATION (err u1009))
(define-constant ERR-INVALID-RECOVERY-ADDRESS (err u1010))
(define-constant ERR-INVALID-PROOF-DATA (err u1011))
(define-constant ERR-CREDENTIAL-LIMIT (err u1012))

;; Constants for Validation
(define-constant MIN-REPUTATION-SCORE u0)
(define-constant MAX-REPUTATION-SCORE u1000)
(define-constant MIN-EXPIRATION-BLOCKS u1)
(define-constant MAX-METADATA-LENGTH u256)
(define-constant MINIMUM-PROOF-SIZE u64)
(define-constant MAX-CREDENTIALS u10)

;; data vars
;;

;; State Variables
(define-data-var admin principal tx-sender)
(define-data-var credential-nonce uint u0)


;; Data Maps
(define-map identities
    principal
    {
        hash: (buff 32),
        credentials: (list 10 principal),
        reputation-score: uint,
        recovery-address: (optional principal),
        last-updated: uint,
        status: (string-ascii 20)
    }
)

(define-map credential-map
    { issuer: principal, nonce: uint }
    {
        subject: principal,
        claim-hash: (buff 32),
        expiration: uint,
        revoked: bool,
        metadata: (string-utf8 256)
    }
)

(define-map zero-knowledge-proofs
    (buff 32)
    {
        prover: principal,
        verified: bool,
        timestamp: uint,
        proof-data: (buff 1024)
    }
)

;; public functions
;;

;; Administrative Functions

;; Sets a new admin for the contract
(define-public (set-admin (new-admin principal))
    (begin
        (asserts! (is-eq tx-sender (var-get admin)) ERR-NOT-AUTHORIZED)
        (asserts! (not (is-eq new-admin tx-sender)) ERR-INVALID-INPUT)
        (var-set admin new-admin)
        (ok true)
    )
)

;; Identity Management

;; Registers a new identity with a hash and optional recovery address
(define-public (register-identity 
    (identity-hash (buff 32)) 
    (recovery-addr (optional principal)))
    (let
        (
            (sender tx-sender)
            (existing-identity (map-get? identities sender))
        )
        (asserts! (is-none existing-identity) ERR-ALREADY-REGISTERED)
        (asserts! (is-valid-hash identity-hash) ERR-INVALID-INPUT)
        (asserts! (is-valid-recovery-address recovery-addr) ERR-INVALID-RECOVERY-ADDRESS)
        
        (map-set identities sender {
            hash: identity-hash,
            credentials: (list),
            reputation-score: u100,
            recovery-address: recovery-addr,
            last-updated: block-height,
            status: "ACTIVE"
        })
        (ok true)
    )
)

;; Credential Management

;; Adds a credential to an identity
(define-public (add-credential-to-identity (subject principal) (credential-principal principal))
    (let
        (
            (sender tx-sender)
            (identity (map-get? identities subject))
        )
        (asserts! (is-some identity) ERR-NOT-REGISTERED)
        (asserts! (is-eq sender (var-get admin)) ERR-NOT-AUTHORIZED)
        (asserts! 
            (can-add-credential (get credentials (unwrap-panic identity))) 
            ERR-CREDENTIAL-LIMIT
        )
        
        (map-set identities subject
            (merge 
                (unwrap-panic identity)
                {
                    credentials: 
                        (unwrap-panic 
                            (as-max-len? 
                                (append (get credentials (unwrap-panic identity)) credential-principal) 
                                u10
                            )
                        )
                }
            )
        )
        (ok true)
    )
)

;; Issues a new credential to a subject
(define-public (issue-credential 
    (subject principal)
    (claim-hash (buff 32))
    (expiration uint)
    (metadata (string-utf8 256)))
    (let
        (
            (sender tx-sender)
            (current-nonce (var-get credential-nonce))
            (credential-id { issuer: sender, nonce: current-nonce })
            (issuer-identity (map-get? identities sender))
            (subject-identity (map-get? identities subject))
        )
        (asserts! (is-some issuer-identity) ERR-NOT-REGISTERED)
        (asserts! (is-some subject-identity) ERR-NOT-REGISTERED)
        (asserts! (is-valid-hash claim-hash) ERR-INVALID-INPUT)
        (asserts! (is-valid-expiration expiration) ERR-INVALID-EXPIRATION)
        (asserts! (is-valid-metadata-length metadata) ERR-INVALID-INPUT)
        
        ;; Increment nonce and record credential
        (var-set credential-nonce (+ current-nonce u1))
        (map-set credential-map credential-id {
            subject: subject,
            claim-hash: claim-hash,
            expiration: expiration,
            revoked: false,
            metadata: metadata
        })
        
        ;; Attempt to add credential to identity
        (try! (add-credential-to-identity subject sender))
        
        (ok true)
    )
)

;; Revokes an existing credential
(define-public (revoke-credential (issuer principal) (nonce uint))
    (let
        (
            (sender tx-sender)
            (credential-id { issuer: issuer, nonce: nonce })
            (credential (map-get? credential-map credential-id))
        )
        (asserts! (is-some credential) ERR-INVALID-CREDENTIAL)
        (asserts! (is-eq sender issuer) ERR-NOT-AUTHORIZED)
        
        (map-set credential-map credential-id 
            (merge (unwrap-panic credential) { revoked: true }))
        (ok true)
    )
)

;; Reputation Management

;; Updates the reputation score of a subject
(define-public (update-reputation (subject principal) (score-change int))
    (let
        (
            (sender tx-sender)
            (identity (map-get? identities subject))
            (current-score 
                (get reputation-score 
                    (unwrap! identity ERR-NOT-REGISTERED)
                )
            )
            (score-change-abs 
                (if (< score-change 0) 
                    (* score-change -1) 
                    score-change
                )
            )
        )
        (asserts! (is-eq sender (var-get admin)) ERR-NOT-AUTHORIZED)
        (asserts! 
            (or 
                (> score-change 0)
                (>= (to-int current-score) score-change-abs)
            ) 
            ERR-INVALID-SCORE
        )
        
        (map-set identities subject
            (merge (unwrap-panic identity)
                { 
                    reputation-score: 
                    (if (> score-change 0)
                        (+ current-score (to-uint score-change))
                        (to-uint (- (to-int current-score) score-change-abs))
                    )
                }
            )
        )
        (ok true)
    )
)

;; Recovery Mechanisms

;; Initiates the recovery process for an identity
(define-public (initiate-recovery 
    (identity principal) 
    (new-hash (buff 32)))
    (let
        (
            (sender tx-sender)
            (identity-data (map-get? identities identity))
            (recovery-address 
                (unwrap! 
                    (get recovery-address (unwrap! identity-data ERR-NOT-REGISTERED)) 
                    ERR-NOT-AUTHORIZED
                )
            )
        )
        (asserts! (is-eq sender recovery-address) ERR-NOT-AUTHORIZED)
        
        (map-set identities identity
            (merge (unwrap-panic identity-data)
                { 
                    hash: new-hash,
                    last-updated: block-height,
                    status: "RECOVERED"
                }
            )
        )
        (ok true)
    )
)


;; Read-Only Query Functions

;; Retrieves the identity data for a given principal
(define-read-only (get-identity (identity principal))
    (map-get? identities identity)
)

;; Retrieves the credential data for a given issuer and nonce
(define-read-only (get-credential (issuer principal) (nonce uint))
    (map-get? credential-map { issuer: issuer, nonce: nonce })
)

;; Verifies if a credential is valid and not revoked
(define-read-only (verify-credential (issuer principal) (nonce uint))
    (let
        (
            (credential 
                (unwrap! 
                    (map-get? credential-map { issuer: issuer, nonce: nonce }) 
                    ERR-INVALID-CREDENTIAL
                )
            )
        )
        (ok (and
            (not (get revoked credential))
            (< block-height (get expiration credential))
        ))
    )
)

;; Retrieves the zero-knowledge proof data for a given proof hash
(define-read-only (get-proof (proof-hash (buff 32)))
    (map-get? zero-knowledge-proofs proof-hash)
)

;; private functions
;;

;; Utility Functions

;; Validates the recovery address ensuring it is not the transaction sender or the admin
(define-private (is-valid-recovery-address (recovery-addr (optional principal)))
    (match recovery-addr
        recovery-principal 
        (and 
            (not (is-eq recovery-principal tx-sender)) 
            (not (is-eq recovery-principal (var-get admin)))
        )
        true
    )
)

;; Validates the proof data ensuring it meets the minimum size and is not empty
(define-private (is-valid-proof-data (proof-data (buff 1024)))
    (and
        (>= (len proof-data) MINIMUM-PROOF-SIZE)
        (not (is-eq proof-data 0x))
    )
)

;; Validates the expiration ensuring it is greater than the current block height plus the minimum expiration blocks
(define-private (is-valid-expiration (expiration uint))
    (> expiration (+ block-height MIN-EXPIRATION-BLOCKS))
)

;; Validates the metadata length ensuring it does not exceed the maximum length
(define-private (is-valid-metadata-length (metadata (string-utf8 256)))
    (<= (len metadata) MAX-METADATA-LENGTH)
)

;; Validates the hash ensuring it is not the zero hash
(define-private (is-valid-hash (hash (buff 32)))
    (not (is-eq hash 0x0000000000000000000000000000000000000000000000000000000000000000))
)

;; Checks if a new credential can be added to the current list of credentials
(define-private (can-add-credential (current-credentials (list 10 principal)))
    (< (len current-credentials) MAX-CREDENTIALS)
)