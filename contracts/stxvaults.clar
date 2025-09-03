;; Contract: StxVault
;; A highly complex STX smart contract in Clarity that implements deposits,
;; withdrawals, staking, rewards, milestone crowdfunding, subscriptions, 
;; auctions, and reputation scoring.

(define-data-var owner principal tx-sender)
(define-data-var balance uint u0)

;; User balances
(define-map user-balances principal uint)

;; Stakers and rewards
(define-map stakers principal { amount: uint, reward: uint })

;; DAO Proposals
(define-map proposals uint { description: (string-ascii 100), votes-for: uint, votes-against: uint, executed: bool })
(define-data-var proposal-counter uint u0)

;; Milestone Crowdfunding Projects
(define-map projects uint { creator: principal, target: uint, raised: uint, milestone: uint, approved: bool, completed: bool })
(define-data-var project-counter uint u0)

;; Subscriptions (recurring payments)
(define-map subscriptions { user: principal, provider: principal } { amount: uint, active: bool })

;; Auctions
(define-map auctions uint { seller: principal, highest-bidder: principal, highest-bid: uint, active: bool })
(define-data-var auction-counter uint u0)

;; Reputation system
(define-map reputation principal { score: int, staked: uint, backed: uint })

(define-private (update-reputation (user principal) (delta int) (staked uint) (backed uint))
    (let ((rep (default-to { score: 0, staked: u0, backed: u0 } (map-get? reputation user))))
        (map-set reputation user { 
            score: (+ (get score rep) delta), 
            staked: (+ (get staked rep) staked), 
            backed: (+ (get backed rep) backed) 
        })
    )
)

;; ---------------- Basic Functions ----------------

(define-public (deposit (amount uint))
    (begin
        (asserts! (> amount u0) (err u100))
        (let ((new-balance (+ (var-get balance) amount))
              (new-user-balance (+ (default-to u0 (map-get? user-balances tx-sender)) amount)))
            (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
            (var-set balance new-balance)
            (map-set user-balances tx-sender new-user-balance)
            (ok amount))
    )
)

(define-public (withdraw (amount uint))
    (begin
        (asserts! (is-eq tx-sender (var-get owner)) (err u100))
        (asserts! (>= (var-get balance) amount) (err u101))
        (try! (stx-transfer? amount (as-contract tx-sender) (var-get owner)))
        (var-set balance (- (var-get balance) amount))
        (ok amount)
    )
)

(define-public (withdraw-user (amount uint))
    (let ((user-balance (default-to u0 (map-get? user-balances tx-sender))))
        (begin
            (asserts! (>= user-balance amount) (err u200))
            (match (stx-transfer? amount (as-contract tx-sender) tx-sender)
                success (begin
                    (map-set user-balances tx-sender (- user-balance amount))
                    (var-set balance (- (var-get balance) amount))
                    (ok amount))
                error (err u201))
        )
    )
)

(define-public (set-owner (new-owner principal))
    (begin
        (asserts! (is-eq tx-sender (var-get owner)) (err u300))
        (asserts! (not (is-eq new-owner (var-get owner))) (err u301))
        (var-set owner new-owner)
        (ok true)
    )
)

;; ---------------- Staking ----------------

(define-public (stake (amount uint))
    (let ((user-balance (default-to u0 (map-get? user-balances tx-sender))))
        (begin
            (asserts! (>= user-balance amount) (err u400))
            (map-set user-balances tx-sender (- user-balance amount))
            (map-set stakers tx-sender { amount: (+ amount (get amount (default-to { amount: u0, reward: u0 } (map-get? stakers tx-sender)))), reward: (get reward (default-to { amount: u0, reward: u0 } (map-get? stakers tx-sender))) })
            (update-reputation tx-sender 5 amount u0)
            (ok amount)
        )
    )
)

(define-public (claim-reward)
    (let ((stake-info (default-to { amount: u0, reward: u0 } (map-get? stakers tx-sender))))
        (begin
            (asserts! (> (get reward stake-info) u0) (err u600))
            (match (stx-transfer? (get reward stake-info) (as-contract tx-sender) tx-sender)
                success (begin
                    (map-set stakers tx-sender { amount: (get amount stake-info), reward: u0 })
                    (update-reputation tx-sender 2 u0 u0)
                    (ok (get reward stake-info)))
                error (err u601))
        )
    )
)

;; ---------------- Governance ----------------

(define-public (create-proposal (description (string-ascii 100)))
    (let ((id (+ u1 (var-get proposal-counter)))
          (proposal { description: description, votes-for: u0, votes-against: u0, executed: false }))
        (begin
            (asserts! (> (len description) u0) (err u800))
            (map-set proposals id proposal)
            (var-set proposal-counter id)
            (ok id)
        )
    )
)

(define-public (vote (proposal-id uint) (support bool))
    (let ((prop (unwrap! (map-get? proposals proposal-id) (err u700))))
        (let ((current-votes-for (get votes-for prop))
              (current-votes-against (get votes-against prop))
              (current-executed (get executed prop))
              (current-description (get description prop)))
            (begin
                (asserts! (not current-executed) (err u701))
                (let ((safe-proposal {
                        description: current-description,
                        votes-for: (if support (+ u1 current-votes-for) current-votes-for),
                        votes-against: (if support current-votes-against (+ u1 current-votes-against)),
                        executed: current-executed
                    }))
                    (begin
                        (map-set proposals proposal-id safe-proposal)
                        (update-reputation tx-sender 1 u0 u0)
                        (ok "Vote cast")))
            )
        )
    )
)

;; ---------------- Subscriptions ----------------

(define-public (subscribe (provider principal) (amount uint))
    (begin
        (asserts! (> amount u0) (err u750))
        (asserts! (not (is-eq provider tx-sender)) (err u751))
        (let ((key { user: tx-sender, provider: provider })
              (new-sub { amount: amount, active: true }))
            (map-set subscriptions key new-sub)
            (update-reputation tx-sender 1 u0 u0)
            (ok "Subscribed"))
    ))


(define-public (unsubscribe (provider principal))
    (let ((key { user: tx-sender, provider: provider })
          (current-sub (unwrap! (map-get? subscriptions key) (err u752))))
        (begin
            (asserts! (get active current-sub) (err u753))
            (map-set subscriptions key { amount: u0, active: false })
            (ok "Unsubscribed")))
)

;; ---------------- Auctions ----------------

(define-public (create-auction (min-bid uint))
    (begin
        (asserts! (> min-bid u0) (err u899))
        (let ((id (+ u1 (var-get auction-counter)))
              (new-auction { seller: tx-sender, highest-bidder: tx-sender, highest-bid: min-bid, active: true }))
            (begin
                (map-set auctions id new-auction)
                (var-set auction-counter id)
                (ok id)
            )
        )
    )
)

(define-public (bid (auction-id uint) (bid-amount uint))
    (let ((auc (unwrap! (map-get? auctions auction-id) (err u902))))
        (let ((current-seller (get seller auc))
              (current-highest-bid (get highest-bid auc)))
            (begin
                (asserts! (get active auc) (err u900))
                (asserts! (> bid-amount current-highest-bid) (err u901))
                (asserts! (not (is-eq tx-sender current-seller)) (err u907))
                (let ((safe-bid { 
                        seller: current-seller, 
                        highest-bidder: tx-sender, 
                        highest-bid: bid-amount, 
                        active: true }))
                    (begin
                        (map-set auctions auction-id safe-bid)
                        (update-reputation tx-sender 2 u0 u0)
                        (ok "Bid placed")))
            )
        )
    )
)

(define-public (close-auction (auction-id uint))
    (let ((auc (unwrap! (map-get? auctions auction-id) (err u905))))
        (let ((current-seller (get seller auc))
              (current-highest-bidder (get highest-bidder auc))
              (current-highest-bid (get highest-bid auc)))
            (begin
                (asserts! (is-eq tx-sender current-seller) (err u903))
                (asserts! (get active auc) (err u904))
                (let ((safe-auction { 
                        seller: current-seller, 
                        highest-bidder: current-highest-bidder, 
                        highest-bid: current-highest-bid, 
                        active: false }))
                    (begin
                        (try! (stx-transfer? current-highest-bid (as-contract tx-sender) current-seller))
                        (map-set auctions auction-id safe-auction)
                        (ok "Auction closed")))
            )
        )
    )
)

;; ---------------- Read-only ----------------

(define-read-only (get-balance)
    (ok (var-get balance))
)

(define-read-only (get-user-balance (user principal))
    (ok (default-to u0 (map-get? user-balances user))))

(define-read-only (get-staker (user principal))
    (ok (default-to { amount: u0, reward: u0 } (map-get? stakers user))))

(define-read-only (get-proposal (proposal-id uint))
    (map-get? proposals proposal-id))

(define-read-only (get-project (project-id uint))
    (map-get? projects project-id))

(define-read-only (get-subscription (user principal) (provider principal))
    (map-get? subscriptions { user: user, provider: provider }))

(define-read-only (get-auction (auction-id uint))
    (map-get? auctions auction-id))

(define-read-only (get-reputation (user principal))
    (default-to { score: 0, staked: u0, backed: u0 } (map-get? reputation user)))
