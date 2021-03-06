(require (lib "pretty.ss"))
(require (lib "match.ss"))
(require (lib "1.ss" "srfi"))

(define data (with-input-from-file "/home/willcock2/asm-as-enum/build/projects/assemblyToSourceAst/fnord.ss" read))

(define visible-labels (make-hash-table))
(for-each (match-lambda
            (`(externally-visible . ,nums)
             (for-each (lambda (n) (hash-table-put! visible-labels (string->symbol (format "label_0x~x" n)) #t)) nums))
            (x (void)))
          data)

(define (find-targets current-label s)
  (let find-targets ((s s))
    (match s
      (`(bb . ,body*) (if (member '(abort) body*) '(abort) (append-map find-targets body*))) ; Assumes no gotos before aborts
      (`(assign . ,_) '())
      (`(var . ,_) '())
      (`(memoryWriteByte . ,_) '())
      (`(memoryWriteWord . ,_) '())
      (`(memoryWriteDWord . ,_) '())
      (`(goto ,l) `(,l))
      (`(if ,_ ,a ,b) (append (find-targets a) (find-targets b)))
      (`(abort) '(abort))
      (`(dispatch-next-instruction) (if current-label `(,(string->symbol (format "continue_~a" current-label))) '()))
      (`(while . ,_) '())
      (`(interrupt ,_) '())
      (`(continue ,name) '())
      (`(loop-point ,name ,s) (find-targets s))
      (x (error "Bad statement" x)))))

(define (statement-count s)
  (match s
    (`(bb . ,body*) (apply + (map statement-count body*)))
    (`(if ,p ,a ,b) (+ 1 (statement-count a) (statement-count b)))
    (`(loop-point ,name ,b) (+ 1 (statement-count b)))
    (_ 1)))

(define (find-common-head a* b*)
  (if (or (null? a*) (null? b*) (not (equal? (car a*) (car b*))))
      (values '() a* b*)
      (let-values (((rcommon ra* rb*) (find-common-head (cdr a*) (cdr b*))))
        (values (cons (car a*) rcommon) ra* rb*))))

(define (find-common-tail a* b*)
  (let-values (((common-rev a*-rev b*-rev) (find-common-head (reverse a*) (reverse b*))))
    (values (reverse common-rev) (reverse a*-rev) (reverse b*-rev))))

(define (contains-cf-discontinuity? s)
  (let c ((s s))
    (match s
      (`(bb . ,a*) (ormap c a*))
      (`(if ,p ,a ,b) (and (c a) (c b)))
      (`(loop-point ,_ ,b) #f)
      (`(goto ,_) #t)
      (`(abort) #t)
      (`(continue ,_) #t)
      (`(dispatch-next-instruction) #t)
      (_ #f))))

(define (collapse-iteration data)
  (define in-edges (make-hash-table))
  (for-each (match-lambda
              (`(externally-visible . ,nums) (void))
              (`(label ,name ,body)
               (let ((targets (find-targets #f body)))
                 (for-each (lambda (t) (hash-table-put! in-edges t (lset-union eq? `(,name) (hash-table-get in-edges t '())))) targets)))
              (x (error "Bad entry" x)))
            data)
  
  (filter-map
   (match-lambda
     (`(externally-visible . ,_) #f)
     (`(label ,l ,body)
      (if (and (not (hash-table-get visible-labels l #f))
               (<= (length (hash-table-get in-edges l '())) 0)
               (not (memq l (hash-table-get in-edges l '()))))
          #f
          (let ((loop-name (gensym 'l)))
            `(label ,l
                    ,((lambda (b)
                        (if (memq l (hash-table-get in-edges l '()))
                            `(loop-point ,loop-name ,b)
                            b))
                      (letrec ((change-body
                                (lambda (s)
                                  ;(pretty-print `(change-body ,s))
                                  (match s
                                    (`(bb . ,body*)
                                     (let ((new-body* (map change-body body*)))
                                       `(bb . ,(append-map (match-lambda (`(bb . ,x*) x*)
                                                                         (s `(,s)))
                                                           new-body*))))
                                    (`(assign . ,_) s)
                                    (`(var . ,_) s)
                                    (`(memoryWriteByte . ,_) s)
                                    (`(memoryWriteWord . ,_) s)
                                    (`(memoryWriteDWord . ,_) s)
                                    (`(goto ,tgt)
                                     (let ((def (ormap (match-lambda (`(label ,l2 ,body) (if (eq? tgt l2) body #f)) (_ #f)) data)))
                                       (if (and (not (hash-table-get visible-labels tgt #f))
                                                (or (<= (length (hash-table-get in-edges tgt '())) 1)
                                                    #;(<= (statement-count def) 10))
                                                (not (memq tgt (hash-table-get in-edges tgt '())))
                                                (not (eq? l tgt)))
                                           (or def
                                               (error "Could not find label" tgt))
                                           (if (eq? l tgt)
                                               `(continue ,loop-name)
                                               s))))
                                    (`(if ,p (bb . ,a*) (bb . ,b*))
                                     (let ((a* (cdr (change-body `(bb . ,a*))))
                                           (b* (cdr (change-body `(bb . ,b*)))))
                                       (let-values (((common rest-a* rest-b*) (find-common-head a* b*)))
                                         (if (not (null? common))
                                             (change-body `(bb ,@common (if ,p (bb . ,rest-a*) (bb . ,rest-b*))))
                                             (let-values (((common rest-a* rest-b*) (find-common-tail a* b*)))
                                               (if (not (null? common))
                                                   (change-body `(bb (if ,p (bb . ,rest-a*) (bb . ,rest-b*)) ,@common))
                                                   (if (boolean? p)
                                                       (change-body (if p `(bb . ,a*) `(bb . ,b*)))
                                                       (if (and (pair? p) (eq? (car p) 'logical-not))
                                                           (change-body `(if ,(cadr p) (bb . ,b*) (bb . ,a*)))
                                                       (if (and (contains-cf-discontinuity? `(bb . ,a*))
                                                                (not (contains-cf-discontinuity? `(bb . ,b*)))
                                                                (not (null? b*)))
                                                           (change-body `(bb (if ,p (bb . ,a*) (bb)) . ,b*))
                                                           (if (and (contains-cf-discontinuity? `(bb . ,b*))
                                                                (not (contains-cf-discontinuity? `(bb . ,a*)))
                                                                (not (null? a*)))
                                                           (change-body `(bb (if ,p (bb) (bb . ,b*)) . ,a*))
                                                       (let ((result `(if ,p (bb . ,a*) (bb . ,b*))))
                                                         (if (and (null? a*) (null? b*))
                                                             '(bb)
                                                             (if (= (length (delete-duplicates (find-targets #f result) eq?)) 1) ; Ignore continues as they form a break in control flow
                                                                 (letrec ((remove-gotos
                                                                           (lambda (s)
                                                                             (match s
                                                                               (`(goto ,l) `(bb))
                                                                               (`(bb . ,body*) `(bb . ,(append-map
                                                                                                        (match-lambda
                                                                                                          (`(bb . ,x*) x*)
                                                                                                          (x (list x)))
                                                                                                        (map remove-gotos body*))))
                                                                               (`(if ,p ,a ,b) `(if ,p ,(remove-gotos a) ,(remove-gotos b)))
                                                                               (`(loop-point ,name ,body) `(loop-point ,name ,(remove-gotos body)))
                                                                               (`(continue ,name) s)
                                                                               (`(while . ,_) s)
                                                                               (`(var . ,_) s)
                                                                               (`(assign . ,_) s)
                                                                               (`(memoryWriteByte . ,_) s)
                                                                               (`(memoryWriteWord . ,_) s)
                                                                               (`(memoryWriteDWord . ,_) s)
                                                                               (`(interrupt ,_) s)
                                                                               (`(abort) s)
                                                                               (`(dispatch-next-instruction) s)
                                                                               (x (error "Bad" x))))))
                                                                   `(bb ,(remove-gotos result)
                                                                        (goto ,(car (find-targets #f result)))))
                                                                 result)))))))))))))
                                    (`(loop-point ,name ,body)
                                     (letrec ((contains-continue?
                                               (match-lambda
                                                 (`(bb . ,a*) (ormap contains-continue? a*))
                                                 (`(if ,_ ,a ,b) (or (contains-continue? a) (contains-continue? b)))
                                                 (`(loop-point ,_ ,b) (contains-continue? b))
                                                 (`(continue ,name2) (eq? name name2))
                                                 (_ #f))))
                                       (if (contains-continue? body)
                                           (match body
                                             (`(bb) `(bb))
                                             (`(bb . ,a*)
                                              (let ((l (last a*)))
                                                (if (contains-continue? l)
                                                    `(loop-point ,name ,(change-body body))
                                                    (change-body `(bb (loop-point ,name (bb . ,(drop-right a* 1))) ,l)))))
                                             (_ `(loop-point ,name ,(change-body body))))
                                           (change-body body))))
                                    (`(continue ,name) s)
                                    (`(abort) s)
                                    (`(dispatch-next-instruction) s)
                                    (`(while . ,_) s)
                                    (`(interrupt ,_) s)
                                    (x (error "Bad statement" x))))))
                        (change-body body)))))))
     (x (error "Bad" x)))
   data))

;(pretty-print data)
#;(let loop ()
  (let ((new-data (collapse-iteration data)))
    ;(pretty-print new-data)
    (if (equal? data new-data)
        (void)
        (begin
          (set! data new-data)
          (loop)))))
;(set! data (collapse-iteration data))

;(set! data (collapse-iteration data))

(define (subst-mappings mappings e)
  (let loop ((e e))
    (match e
      ((? symbol?) (if (assq e mappings) (cdr (assq e mappings)) e))
      ((? number?) e)
      ((? boolean?) e)
      ((? list?) (cons (car e) (map loop (cdr e))))
      (_ (error "subst-mappings" e)))))

(define (flush-mappings mappings)
  (map (match-lambda (`(,v . ,var) `(assign ,v ,var))) mappings))

(define (modified-variables s)
  (match s
    (`(bb . ,ls) (apply lset-union eq? (map modified-variables ls)))
    (`(if ,p ,a ,b) (lset-union eq? (modified-variables a) (modified-variables b)))
    (`(loop-point ,_ ,body) (modified-variables body))
    (`(while ,_ ,body) (modified-variables body))
    (`(assign ,var ,_) (list var))
    (`(var ,_ ,_) '())
    (`(abort) '())
    (`(continue ,_) '())
    (`(break) '())
    (`(goto ,_) '())
    (`(dispatch-next-instruction) '())
    (`(interrupt ,_) '()) ; FIXME
    (`(memoryWriteByte ,_ ,_) '())
    (`(memoryWriteWord ,_ ,_) '())
    (`(memoryWriteDWord ,_ ,_) '())
    (_ (error "modified-variables" s))))

(define (track-variable-defs data)
  (map
   (match-lambda
     (`(label ,name ,body)
      (let-values (((new-body _)
                    (let track ((s body) (mappings '()))
                      ;(pretty-print `(track ,s ,mappings))
                      (match s
                        (`(bb . ,rest)
                         (let-values (((new-rest new-mappings)
                                       (let loop ((x rest) (mappings mappings))
                                         (if (null? x)
                                             (values '() mappings)
                                             (let-values (((new-head mappings-head)
                                                           (track (car x) mappings)))
                                               (let-values (((new-tail mappings-tail)
                                                             (loop (cdr x) mappings-head)))
                                                 (values `(,new-head . ,new-tail) mappings-tail)))))))
                           (values `(bb . ,new-rest) new-mappings)))
                        (`(assign ,lhs ,rhs)
                         (let ((var-name (gensym lhs)))
                           (values
                            `(var ,var-name ,(subst-mappings mappings rhs))
                            (cons (cons lhs var-name) (filter (match-lambda (`(,v . ,val) (not (eq? v lhs)))) mappings)))))
                        (`(var ,name ,rhs)
                         (values
                          `(var ,name ,(subst-mappings mappings rhs))
                          mappings))
                        (`(memoryWriteByte ,addr ,data) (values `(memoryWriteByte ,(subst-mappings mappings addr) ,(subst-mappings mappings data)) mappings))
                        (`(memoryWriteWord ,addr ,data) (values `(memoryWriteWord ,(subst-mappings mappings addr) ,(subst-mappings mappings data)) mappings))
                        (`(memoryWriteDWord ,addr ,data) (values `(memoryWriteDWord ,(subst-mappings mappings addr) ,(subst-mappings mappings data)) mappings))
                        (`(loop-point ,name ,body)
                         (let-values (((new-body body-mappings)
                                       (track body '())))
                           (values
                            `(bb ,@(flush-mappings mappings)
                                 (loop-point ,name (bb ,new-body ,@(flush-mappings body-mappings))))
                            '())))
                        (`(if ,p ,a ,b)
                         (let-values (((new-a a-mappings) (track a mappings))
                                      ((new-b b-mappings) (track b mappings)))
                           (let* ((common-mappings (lset-intersection equal? a-mappings b-mappings))
                                  (a-mappings-to-flush (lset-difference equal? a-mappings common-mappings))
                                  (b-mappings-to-flush (lset-difference equal? b-mappings common-mappings)))
                             (values
                              `(if ,(subst-mappings mappings p)
                                   (bb
                                    ,new-a
                                    ,@(flush-mappings a-mappings-to-flush))
                                   (bb
                                    ,new-b
                                    ,@(flush-mappings b-mappings-to-flush)))
                              common-mappings))))
                        (`(while ,test ,body)
                         (let ((modified-vars (modified-variables body)))
                           (values
                            `(bb ,@(flush-mappings (filter (match-lambda (`(,var . ,_) (memq var modified-vars))) mappings))
                                 (while ,(subst-mappings (filter (match-lambda (`(,var . ,_) (not (memq var modified-vars)))) mappings) test)
                                        ,(let-values (((new-body body-mappings)
                                                       (track body (filter (match-lambda (`(,var . ,_) (not (memq var modified-vars)))) mappings))))
                                           `(bb ,new-body
                                                ,@(flush-mappings (filter (match-lambda (`(,var . ,_) (memq var modified-vars))) body-mappings))))))
                            (filter (match-lambda (`(,var . ,_) (not (memq var modified-vars)))) mappings))))
                        (`(interrupt ,i) (values `(bb ,@(flush-mappings mappings) (interrupt ,i)) '()))
                        (`(continue ,l) (values `(bb ,@(flush-mappings mappings) (continue ,l)) '()))
                        (`(goto ,l) (values `(bb ,@(flush-mappings mappings) (goto ,l)) '()))
                        (`(abort) (values `(bb ,@(flush-mappings mappings) (abort)) '()))
                        (`(break) (values `(break) mappings))
                        (`(dispatch-next-instruction) (values `(bb ,@(flush-mappings mappings) (dispatch-next-instruction)) '()))
                        (_ (error "Unknown statement" s))))))
        `(label ,name ,new-body)))
     (x (error "track-variable-defs" x)))
   data))

(define (flatten-basic-blocks s)
  (match s
    (`(bb . ,rest)
     (let ((r (append-map (lambda (s2)
                            (match (flatten-basic-blocks s2)
                              (`(bb . ,x) x)
                              (s3 (list s3))))
                          rest)))
       (if (= (length r) 1)
           (car r)
           `(bb . ,r))))
    (`(if ,p ,a ,b) `(if ,p ,(flatten-basic-blocks a) ,(flatten-basic-blocks b)))
    (`(loop-point ,name ,body) `(loop-point ,name ,(flatten-basic-blocks body)))
    (`(while ,test ,body) `(while ,test ,(flatten-basic-blocks body)))
    (_ s)))

(define (flatten-basic-blocks-top data)
  (map (match-lambda (`(label ,l ,body) `(label ,l ,(flatten-basic-blocks body)))) data))

;(set! data (flatten-basic-blocks-top (track-variable-defs data)))

#;(with-output-to-file "/home/willcock2/asm-as-enum/build/projects/assemblyToSourceAst/fnord-cfg.dot"
  (lambda ()
    (printf "digraph cfg {\n")
    (printf "size=\"100,100\"\n")
    (for-each (match-lambda
                (`(externally-visible . ,nums) (void))
                (`(label ,name ,body)
                 (printf "~a [label=\"~a\", color=\"~a\"]\n" name name (if (hash-table-get visible-labels name #f) "green" "black"))
                 ;(if (hash-table-get visible-labels name #f) (printf "dispatch-next-instruction -> ~a\n" name))
                 (let ((targets (delete-duplicates (find-targets name body) eq?)))
                   (for-each (lambda (t) (printf "~a -> ~a\n" name t)) targets)))
                (x (error "Bad entry" x)))
              data)
    (printf "}\n")
    ) 'replace)

(define assigned-values (make-hash-table))
(for-each
 (match-lambda 
   (`(externally-visible . ,_) (void))
   (`(label ,lname ,body)
                (let find-assigned-values ((s body))
                  (match s
                    (`(bb . ,ls) (for-each find-assigned-values ls))
                    (`(var ,name ,def) (hash-table-put! assigned-values name (lset-union equal? (list def) (hash-table-get assigned-values name '()))))
                    (`(assign ,name ,def) (hash-table-put! assigned-values name (lset-union equal? (list def) (hash-table-get assigned-values name '()))))
                    (`(if ,p ,a ,b) (find-assigned-values a) (find-assigned-values b))
                    (`(while ,p ,b) (find-assigned-values b))
                    (`(loop-point ,name ,b) (find-assigned-values b))
                    (`(continue ,name) (void))
                    (`(break) (void))
                    (`(memoryWriteByte . ,_) (void))
                    (`(memoryWriteWord . ,_) (void))
                    (`(memoryWriteDWord . ,_) (void))
                    (`(dispatch-next-instruction) (void))
                    (`(goto ,_) (void))
                    (`(abort) (void))
                    (`(interrupt ,_) (void))
                    (_ (error "Bad stmt" s))))))
 data)

#;(hash-table-for-each assigned-values
                     (lambda (name defs)
                       (pretty-print `(,name ,defs))))

(define assigned-value-mappings
  (filter
   (lambda (p) (not (eq? (car p) (cdr p))))
   (hash-table-map assigned-values
                   (lambda (name defs)
                     (cons
                      name
                      (let lookup-for-name ((name name))
                        (let ((p (hash-table-get assigned-values name #f)))
                          (if (and (list? p)
                                   (= (length p) 1)
                                   (or (symbol? (car p)) (number? (car p)) (boolean? (car p))))
                              (let ((new-name (car p)))
                                (if (symbol? new-name)
                                    (lookup-for-name new-name)
                                    new-name))
                              name))))))))

(define (used-variables e)
  (cond
    ((symbol? e) (list e))
    ((number? e) '())
    ((boolean? e) '())
    ((list? e) (apply lset-union eq? (map used-variables (cdr e))))
    (else (error "used-variables" e))))

(hash-table-for-each assigned-values
                     (lambda (name defs)
                       (if (or (not (= (length defs) 1))
                               (not (or (symbol? (car defs)) (number? (car defs)) (boolean? (car defs)))))
                           (pretty-print `(,name ,(apply lset-union eq? (map (lambda (e) (used-variables (subst-mappings assigned-value-mappings e))) defs)))))))

;(pretty-print data)