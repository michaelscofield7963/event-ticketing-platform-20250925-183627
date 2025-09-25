;; Event Ticketing Platform Smart Contract
;; Anti-fraud event ticketing system with resale controls and attendance verification

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-event-not-found (err u102))
(define-constant err-ticket-not-found (err u103))
(define-constant err-invalid-ticket-holder (err u104))
(define-constant err-ticket-already-used (err u105))
(define-constant err-event-capacity-exceeded (err u106))
(define-constant err-invalid-price (err u107))
(define-constant err-resale-not-allowed (err u108))
(define-constant err-price-exceeds-maximum (err u109))
(define-constant err-ticket-not-transferable (err u110))
(define-constant err-invalid-event-details (err u111))
(define-constant err-event-already-started (err u112))
(define-constant err-attendee-already-checked-in (err u113))
(define-constant err-invalid-entrance (err u114))
(define-constant max-resale-markup u150) ;; 150% of original price (50% markup)
(define-constant min-ticket-price u1000000) ;; 0.001 STX minimum

;; Data structures
(define-map events uint {
    name: (string-ascii 100),
    description: (string-ascii 500),
    organizer: principal,
    venue: (string-ascii 100),
    event-date: uint,
    capacity: uint,
    tickets-sold: uint,
    base-price: uint,
    resale-allowed: bool,
    max-resale-price: uint,
    active: bool,
    created-at: uint
})

(define-map tickets uint {
    event-id: uint,
    owner: principal,
    original-price: uint,
    current-price: uint,
    seat-number: (optional (string-ascii 20)),
    section: (optional (string-ascii 20)),
    tier: (string-ascii 20),
    is-used: bool,
    is-transferable: bool,
    minted-at: uint,
    metadata-uri: (optional (string-ascii 200))
})

(define-map ticket-transfers { ticket-id: uint, transfer-id: uint } {
    from: principal,
    to: principal,
    price: uint,
    transfer-fee: uint,
    timestamp: uint,
    transfer-type: (string-ascii 20) ;; "sale", "gift", "resale"
})

(define-map event-staff { event-id: uint, staff-member: principal } {
    role: (string-ascii 20), ;; "organizer", "security", "usher", "manager"
    permissions: uint, ;; bitmask for different permissions
    added-at: uint
})

(define-map attendance-records { event-id: uint, ticket-id: uint } {
    attendee: principal,
    check-in-time: uint,
    entrance: (string-ascii 50),
    staff-member: principal,
    verified: bool
})

(define-map resale-listings uint {
    ticket-id: uint,
    seller: principal,
    price: uint,
    listed-at: uint,
    expires-at: uint,
    active: bool
})

;; Contract state variables
(define-data-var next-event-id uint u1)
(define-data-var next-ticket-id uint u1)
(define-data-var next-transfer-id uint u1)
(define-data-var next-listing-id uint u1)
(define-data-var total-events-created uint u0)
(define-data-var total-tickets-issued uint u0)
(define-data-var total-attendance-records uint u0)
(define-data-var platform-fee-percentage uint u250) ;; 2.5% platform fee
(define-data-var resale-fee-percentage uint u500) ;; 5% resale fee

;; Authorization functions
(define-private (is-contract-owner)
    (is-eq tx-sender contract-owner))

(define-private (is-event-organizer (event-id uint))
    (match (map-get? events event-id)
        event-data (is-eq tx-sender (get organizer event-data))
        false
    )
)

(define-private (is-event-staff (event-id uint) (staff-member principal))
    (is-some (map-get? event-staff { event-id: event-id, staff-member: staff-member }))
)

(define-private (is-ticket-owner (ticket-id uint) (user principal))
    (match (map-get? tickets ticket-id)
        ticket-data (is-eq user (get owner ticket-data))
        false
    )
)

(define-private (validate-price (price uint))
    (>= price min-ticket-price))

(define-private (calculate-platform-fee (price uint))
    (/ (* price (var-get platform-fee-percentage)) u10000))

(define-private (calculate-resale-fee (price uint))
    (/ (* price (var-get resale-fee-percentage)) u10000))

;; Event management functions
(define-public (create-event 
    (name (string-ascii 100))
    (description (string-ascii 500))
    (venue (string-ascii 100))
    (event-date uint)
    (capacity uint)
    (base-price uint)
    (resale-allowed bool)
)
    (let (
        (event-id (var-get next-event-id))
        (max-resale (if resale-allowed 
            (/ (* base-price max-resale-markup) u100)
            u0
        ))
    )
        (asserts! (validate-price base-price) err-invalid-price)
        (asserts! (> capacity u0) err-invalid-event-details)
        (asserts! (> event-date block-height) err-invalid-event-details)
        
        (map-set events event-id {
            name: name,
            description: description,
            organizer: tx-sender,
            venue: venue,
            event-date: event-date,
            capacity: capacity,
            tickets-sold: u0,
            base-price: base-price,
            resale-allowed: resale-allowed,
            max-resale-price: max-resale,
            active: true,
            created-at: block-height
        })
        
        (map-set event-staff { event-id: event-id, staff-member: tx-sender } {
            role: "organizer",
            permissions: u255, ;; Full permissions
            added-at: block-height
        })
        
        (var-set next-event-id (+ event-id u1))
        (var-set total-events-created (+ (var-get total-events-created) u1))
        
        (ok { event-id: event-id, organizer: tx-sender, capacity: capacity })
    )
)

(define-public (add-event-staff (event-id uint) (staff-member principal) (role (string-ascii 20)) (permissions uint))
    (begin
        (asserts! (is-event-organizer event-id) err-not-authorized)
        (asserts! (is-some (map-get? events event-id)) err-event-not-found)
        
        (map-set event-staff { event-id: event-id, staff-member: staff-member } {
            role: role,
            permissions: permissions,
            added-at: block-height
        })
        
        (ok { event-id: event-id, staff-member: staff-member, role: role })
    )
)

;; Ticket management functions
(define-public (mint-tickets 
    (event-id uint)
    (quantity uint)
    (recipient principal)
    (tier (string-ascii 20))
    (seat-info (optional { seat-number: (string-ascii 20), section: (string-ascii 20) }))
)
    (match (map-get? events event-id)
        event-data
        (let (
            (current-tickets (get tickets-sold event-data))
            (new-total (+ current-tickets quantity))
            (base-price (get base-price event-data))
        )
            (asserts! (is-event-organizer event-id) err-not-authorized)
            (asserts! (get active event-data) err-event-not-found)
            (asserts! (<= new-total (get capacity event-data)) err-event-capacity-exceeded)
            
            (map-set events event-id
                (merge event-data { tickets-sold: new-total })
            )
            
            (let (
                (start-ticket-id (var-get next-ticket-id))
                (end-ticket-id (+ start-ticket-id quantity))
            )
                (var-set next-ticket-id end-ticket-id)
                (var-set total-tickets-issued (+ (var-get total-tickets-issued) quantity))
                
                ;; Create individual tickets (simplified for demonstration)
                (map-set tickets start-ticket-id {
                    event-id: event-id,
                    owner: recipient,
                    original-price: base-price,
                    current-price: base-price,
                    seat-number: (if (is-some seat-info) 
                        (some (get seat-number (unwrap-panic seat-info)))
                        none
                    ),
                    section: (if (is-some seat-info) 
                        (some (get section (unwrap-panic seat-info)))
                        none
                    ),
                    tier: tier,
                    is-used: false,
                    is-transferable: true,
                    minted-at: block-height,
                    metadata-uri: none
                })
                
                (ok { 
                    start-ticket-id: start-ticket-id, 
                    quantity: quantity, 
                    recipient: recipient,
                    event-id: event-id
                })
            )
        )
        err-event-not-found
    )
)

(define-public (transfer-ticket (ticket-id uint) (recipient principal) (price uint) (transfer-type (string-ascii 20)))
    (match (map-get? tickets ticket-id)
        ticket-data
        (let (
            (transfer-id (var-get next-transfer-id))
            (platform-fee (calculate-platform-fee price))
        )
            (asserts! (is-ticket-owner ticket-id tx-sender) err-invalid-ticket-holder)
            (asserts! (get is-transferable ticket-data) err-ticket-not-transferable)
            (asserts! (not (get is-used ticket-data)) err-ticket-already-used)
            
            ;; Validate resale conditions if this is a resale
            (if (is-eq transfer-type "resale")
                (match (map-get? events (get event-id ticket-data))
                    event-data
                    (begin
                        (asserts! (get resale-allowed event-data) err-resale-not-allowed)
                        (asserts! (<= price (get max-resale-price event-data)) err-price-exceeds-maximum)
                        true
                    )
                    false
                )
                true
            )
            
            ;; Process payment if price > 0
            (if (> price u0)
                (begin
                    (try! (stx-transfer? (+ price platform-fee) recipient tx-sender))
                    (try! (stx-transfer? platform-fee tx-sender contract-owner))
                    true
                )
                true
            )
            
            ;; Update ticket ownership
            (map-set tickets ticket-id
                (merge ticket-data { 
                    owner: recipient,
                    current-price: price
                })
            )
            
            ;; Record transfer
            (map-set ticket-transfers { ticket-id: ticket-id, transfer-id: transfer-id } {
                from: tx-sender,
                to: recipient,
                price: price,
                transfer-fee: platform-fee,
                timestamp: block-height,
                transfer-type: transfer-type
            })
            
            (var-set next-transfer-id (+ transfer-id u1))
            
            (ok { 
                ticket-id: ticket-id, 
                new-owner: recipient, 
                transfer-id: transfer-id,
                price: price
            })
        )
        err-ticket-not-found
    )
)

;; Resale marketplace functions
(define-public (list-for-resale (ticket-id uint) (price uint) (duration uint))
    (match (map-get? tickets ticket-id)
        ticket-data
        (match (map-get? events (get event-id ticket-data))
            event-data
            (let (
                (listing-id (var-get next-listing-id))
                (expires-at (+ block-height duration))
            )
                (asserts! (is-ticket-owner ticket-id tx-sender) err-invalid-ticket-holder)
                (asserts! (get resale-allowed event-data) err-resale-not-allowed)
                (asserts! (<= price (get max-resale-price event-data)) err-price-exceeds-maximum)
                (asserts! (not (get is-used ticket-data)) err-ticket-already-used)
                
                (map-set resale-listings listing-id {
                    ticket-id: ticket-id,
                    seller: tx-sender,
                    price: price,
                    listed-at: block-height,
                    expires-at: expires-at,
                    active: true
                })
                
                (var-set next-listing-id (+ listing-id u1))
                
                (ok { listing-id: listing-id, ticket-id: ticket-id, price: price })
            )
            err-event-not-found
        )
        err-ticket-not-found
    )
)

;; Attendance verification functions
(define-public (check-in-attendee (ticket-id uint) (entrance (string-ascii 50)))
    (match (map-get? tickets ticket-id)
        ticket-data
        (let (
            (event-id (get event-id ticket-data))
            (attendee (get owner ticket-data))
        )
            (asserts! (or 
                (is-event-organizer event-id)
                (is-event-staff event-id tx-sender)
            ) err-not-authorized)
            (asserts! (not (get is-used ticket-data)) err-ticket-already-used)
            (asserts! (is-none (map-get? attendance-records { event-id: event-id, ticket-id: ticket-id })) 
                err-attendee-already-checked-in)
            
            ;; Mark ticket as used
            (map-set tickets ticket-id
                (merge ticket-data { is-used: true })
            )
            
            ;; Record attendance
            (map-set attendance-records { event-id: event-id, ticket-id: ticket-id } {
                attendee: attendee,
                check-in-time: block-height,
                entrance: entrance,
                staff-member: tx-sender,
                verified: true
            })
            
            (var-set total-attendance-records (+ (var-get total-attendance-records) u1))
            
            (ok { 
                ticket-id: ticket-id, 
                attendee: attendee, 
                check-in-time: block-height,
                entrance: entrance
            })
        )
        err-ticket-not-found
    )
)

;; Administrative functions
(define-public (set-platform-fee (new-fee-percentage uint))
    (begin
        (asserts! (is-contract-owner) err-owner-only)
        (asserts! (<= new-fee-percentage u1000) err-invalid-price) ;; Max 10%
        
        (var-set platform-fee-percentage new-fee-percentage)
        (ok { new-fee-percentage: new-fee-percentage })
    )
)

(define-public (deactivate-event (event-id uint))
    (begin
        (asserts! (is-event-organizer event-id) err-not-authorized)
        
        (match (map-get? events event-id)
            event-data
            (begin
                (map-set events event-id
                    (merge event-data { active: false })
                )
                (ok { event-id: event-id, deactivated: true })
            )
            err-event-not-found
        )
    )
)

;; Read-only functions
(define-read-only (get-event-details (event-id uint))
    (map-get? events event-id)
)

(define-read-only (get-ticket-details (ticket-id uint))
    (map-get? tickets ticket-id)
)

(define-read-only (verify-ticket (ticket-id uint) (holder principal))
    (match (map-get? tickets ticket-id)
        ticket-data
        {
            valid: (and 
                (is-eq (get owner ticket-data) holder)
                (not (get is-used ticket-data))
            ),
            owner: (get owner ticket-data),
            event-id: (get event-id ticket-data),
            is-used: (get is-used ticket-data)
        }
        {
            valid: false,
            owner: contract-owner,
            event-id: u0,
            is-used: true
        }
    )
)

(define-read-only (get-attendance-record (event-id uint) (ticket-id uint))
    (map-get? attendance-records { event-id: event-id, ticket-id: ticket-id })
)

(define-read-only (get-event-stats (event-id uint))
    (match (map-get? events event-id)
        event-data
        {
            tickets-sold: (get tickets-sold event-data),
            capacity: (get capacity event-data),
            capacity-utilization: (/ (* (get tickets-sold event-data) u100) (get capacity event-data)),
            active: (get active event-data)
        }
        {
            tickets-sold: u0,
            capacity: u0,
            capacity-utilization: u0,
            active: false
        }
    )
)

(define-read-only (get-contract-stats)
    {
        total-events-created: (var-get total-events-created),
        total-tickets-issued: (var-get total-tickets-issued),
        total-attendance-records: (var-get total-attendance-records),
        platform-fee-percentage: (var-get platform-fee-percentage),
        resale-fee-percentage: (var-get resale-fee-percentage)
    }
)

(define-read-only (get-resale-listing (listing-id uint))
    (map-get? resale-listings listing-id)
)

(define-read-only (is-authorized-staff (event-id uint) (staff-member principal))
    (is-some (map-get? event-staff { event-id: event-id, staff-member: staff-member }))
)

(define-read-only (calculate-transfer-cost (price uint))
    {
        price: price,
        platform-fee: (calculate-platform-fee price),
        total-cost: (+ price (calculate-platform-fee price))
    }
)


;; title: ticket-manager
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

