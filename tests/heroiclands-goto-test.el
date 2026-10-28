;;; heroiclands-goto-test.el --- Wikilink destination checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'heroiclands-goto)

(ert-deftest heroiclands-goto-follow-uses-the-records-owning-project ()
  (let* ((directory (make-temp-file "heroiclands-goto-" t))
         (local (expand-file-name "local" directory))
         (foreign (expand-file-name "foreign" directory))
         (local-index (expand-file-name "local.jsonl" directory))
         (foreign-index (expand-file-name "foreign.jsonl" directory))
         (heroiclands-goto--cache nil)
         opened)
    (unwind-protect
        (progn
          (make-directory local)
          (make-directory foreign)
          (with-temp-file foreign-index
            (insert (json-encode
                     '((package . "other")
                       (type . "lore")
                       (address . ((slug . "lore-beta")
                                   (canonical . "other-none-lore-beta")))
                       (file . ((path . "Foreign.md"))))) "\n"))
          (with-temp-file local-index
            (insert (json-encode
                     '((package . "local")
                       (type . "lore")
                       (address . ((slug . "lore-beta")
                                   (canonical . "local-none-lore-beta")))
                       (file . ((path . "Local.md"))))) "\n"))
          (with-temp-buffer
            (setq default-directory local)
            (cl-letf (((symbol-function 'heroiclands-index--root)
                       (lambda () local))
                      ((symbol-function 'heroiclands-index-sources)
                       (lambda (_root)
                         (list (cons foreign-index foreign)
                               (cons local-index local))))
                      ((symbol-function 'heroiclands-goto--content-dir)
                       (lambda (root) (if (equal root foreign) "notes" nil)))
                      ((symbol-function 'xref-push-marker-stack)
                       (lambda () nil))
                      ((symbol-function 'find-file)
                       (lambda (file) (push file opened))))
              (dolist (target '("other-none-lore-beta" "lore-beta"))
                (erase-buffer)
                (insert "[[" target "]]")
                (goto-char (+ (point-min) 3))
                (heroiclands-goto-follow))))
          (should (equal (nreverse opened)
                         (list (expand-file-name "Foreign.md" (expand-file-name "notes" foreign))
                               (expand-file-name "Local.md" (expand-file-name "assets/content" local))))))
      (delete-directory directory t))))

(ert-deftest heroiclands-goto-closes-the-exact-server-selection ()
  (dolist (case '(("sohl-being-bctrncml" "Xerathian Bactrian Camel"
                  "thalorna-sohl-being-bctrncml"
                  "[[sohl-being-bctrncml|Xerathian Bactrian Camel]]")
                 ("sohl-none-being-bctrncml" "Bactrian Camel"
                  "sohl-none-being-bctrncml"
                  "[[sohl-none-being-bctrncml|Bactrian Camel]]")
                 ("being-orca" "Killer Whale" "sohl-note-being-orca"
                  "[[being-orca|Killer Whale]]")))
    (with-temp-buffer
      (insert "[[" (nth 0 case) "]]")
      (goto-char (point-max))
      (setq heroiclands-goto--entry (copy-marker (+ (point-min) 2))
            heroiclands-goto--selected
            (list :address (nth 0 case) :canonical (nth 2 case)
                  :display (nth 1 case)
                  :entry (marker-position heroiclands-goto--entry)))
      (let ((last-command-event ?\]))
        (heroiclands-goto--close-link))
      (should (equal (buffer-string) (nth 3 case)))
      (should-not heroiclands-goto--selected)
      (should-not heroiclands-goto--entry))))

(ert-deftest heroiclands-goto-keeps-an-authored-display-and-a-settled-link ()
  (with-temp-buffer
    (insert "[[being-orca|The whale]]")
    (goto-char (point-max))
    (setq heroiclands-goto--entry (copy-marker (+ (point-min) 2))
          heroiclands-goto--selected
          (list :address "being-orca" :canonical "sohl-note-being-orca"
                :display "Orca" :entry (+ (point-min) 2)))
    (let ((last-command-event ?\]))
      (heroiclands-goto--close-link))
    (should (equal (buffer-string) "[[being-orca|The whale]]"))
    (setq heroiclands-goto--entry nil)
    (insert "x")
    (let ((last-command-event ?\]))
      (heroiclands-goto--close-link))
    (should (equal (buffer-string) "[[being-orca|The whale]]x"))))

(ert-deftest heroiclands-goto-closes-electric-paired-brackets ()
  (with-temp-buffer
    (insert "[[]]")
    (goto-char (+ (point-min) 2))
    (let ((last-command-event ?\[))
      (heroiclands-goto--arm))
    (should (heroiclands-goto--armed-p))
    (insert "being-orca")
    (setq heroiclands-goto--selected
          (list :address "being-orca" :canonical "sohl-note-being-orca"
                :display "Orca"
                :entry (marker-position heroiclands-goto--entry)))
    (forward-char 2)
    (let ((last-command-event ?\]))
      (heroiclands-goto--close-link))
    (should (equal (buffer-string) "[[being-orca|Orca]]"))))

(ert-deftest heroiclands-goto-distinguishes-same-file-addresses ()
  (let ((table (make-hash-table :test #'equal)))
    (dolist (system '("sohl" "none"))
      (let ((record (list :address (list :canonical
                                         (format "thalorna-%s-being-bctrncml" system))
                          :name (list :full "Bactrian Camel")
                          :file (list :path "Camel.md"))))
        (puthash (plist-get (plist-get record :address) :canonical) record table)))
    (should (= (length (heroiclands-goto--name-matches
                        "Bactrian Camel" (list :table table)))
               2))))

(defun heroiclands-goto-test--record (canonical slug full &optional forms)
  "Make an indexed note with CANONICAL identity, SLUG, FULL name and FORMS.
FORMS is the list of English forms; a `name' key may also be given as a
plist of language code to forms in place of that list."
  (list :address (list :canonical canonical :slug slug)
        :name (append (list :full full)
                      (if (keywordp (car-safe forms)) forms (and forms (list :en forms))))
        :file (list :path "Shared.md")
        :anchors '((:slug "dossier" :name "Dossier"))))

(defun heroiclands-goto-test--index (&rest records)
  "Index RECORDS, letting the last record own a colliding short slug."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (record records)
      (puthash (plist-get (plist-get record :address) :canonical) record table)
      (puthash (plist-get (plist-get record :address) :slug) record table))
    (list :table table)))

(defmacro heroiclands-goto-test--closing (text index &rest body)
  "Run BODY at the closing brackets of TEXT with INDEX available."
  (declare (indent 2))
  `(with-temp-buffer
     (insert ,text)
     (setq heroiclands-goto--entry (copy-marker (+ (point-min) 2)))
     (cl-letf (((symbol-function 'heroiclands-index--root)
                (lambda () default-directory))
               ((symbol-function 'heroiclands-index-files)
                (lambda (_root) '("index.jsonl")))
               ((symbol-function 'heroiclands-goto--index)
                (lambda (_files) ,index)))
       (let ((last-command-event ?\])) ,@body))))

(ert-deftest heroiclands-goto-partial-names-fold-accents-and-case ()
  (let* ((record (heroiclands-goto-test--record
                  "thalorna-none-lore-veldirno" "lore-veldirno"
                  "City of Véldirno" '("The Northern Jewel")))
         (index (heroiclands-goto-test--index record)))
    (dolist (query '("Veldirno" "VÉLDIRNO" "eldir" "northern"))
      (heroiclands-goto-test--closing (format "[[%s#dossier]]" query) index
        (heroiclands-goto--close-link)
        (should (equal (buffer-string)
                       "[[lore-veldirno#dossier|City of Véldirno]]"))))
    ;; Substring matching does not search Address fragments or erase spaces.
    (dolist (query '("thalorna-none" "lore-vel" "vel dirno" "!!!"))
      (should-not (heroiclands-goto--name-matches query index)))))

(ert-deftest heroiclands-goto-exact-matches-precede-partial-names ()
  (let* ((partial (heroiclands-goto-test--record
                   "a-none-lore-town" "lore-town" "City of Veldirno"))
         (exact (heroiclands-goto-test--record
                 "a-none-lore-river" "lore-river" "Veldirno" '("Silver River")))
         (other (heroiclands-goto-test--record
                 "a-none-lore-alias" "lore-alias" "Northern City" '("VELDIRNO")))
         (index (heroiclands-goto-test--index partial exact other)))
    (should (= 2 (length (heroiclands-goto--name-matches "veldirno" index))))
    (heroiclands-goto-test--closing "[[Silver River]]" index
      (heroiclands-goto--close-link)
      (should (equal (buffer-string) "[[lore-river|Silver River]]")))
    (heroiclands-goto-test--closing "[[lore-town]]" index
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (ert-fail "Exact Address must not prompt"))))
        (heroiclands-goto--close-link))
      (should (equal (buffer-string) "[[lore-town|City of Veldirno]]")))))

(ert-deftest heroiclands-goto-asks-for-a-choice-on-ambiguous-name ()
  (let* ((foreign (heroiclands-goto-test--record
                   "thalorna-sohl-being-camel" "being-camel" "Bactrian Camel"))
         (local (heroiclands-goto-test--record
                 "thalorna-none-being-camel" "being-camel" "Bactrian Camel"))
         (index (heroiclands-goto-test--index foreign local)))
    (dolist (query '("Bactrian Camel" "camel"))
      (heroiclands-goto-test--closing (format "[[%s#dossier]]" query) index
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt choices _predicate require-match &rest _)
                     (should require-match)
                     (should (equal (mapcar #'car choices)
                                    '("Bactrian Camel — thalorna-none-being-camel"
                                      "Bactrian Camel — thalorna-sohl-being-camel")))
                     "Bactrian Camel — thalorna-sohl-being-camel")))
          (heroiclands-goto--close-link))
        (should (equal (buffer-string)
                       "[[thalorna-sohl-being-camel#dossier|Bactrian Camel]]"))
        (should-not heroiclands-goto--entry)))))

(ert-deftest heroiclands-goto-cancel-choice-and-bad-anchor-preserve-source ()
  (let* ((index (heroiclands-goto-test--index
                 (heroiclands-goto-test--record "a-none-lore-one" "lore-one" "First Town")
                 (heroiclands-goto-test--record "b-none-lore-two" "lore-two" "Second Town"))))
    (heroiclands-goto-test--closing "[[Town]]" index
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil))))
        (should (eq 'quit (condition-case nil (heroiclands-goto--close-link)
                           (quit 'quit)))))
      (should (equal (buffer-string) "[[Town]]"))
      (should-not heroiclands-goto--entry))
    (heroiclands-goto-test--closing "[[First#missing]]" index
      (should-error (heroiclands-goto--close-link) :type 'user-error)
      (should (equal (buffer-string) "[[First#missing]]")))
    (heroiclands-goto-test--closing "[[Town|My display]]" index
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (ert-fail "Authored labels must not prompt"))))
        (heroiclands-goto--close-link))
      (should (equal (buffer-string) "[[Town|My display]]")))))

(ert-deftest heroiclands-goto-partial-names-use-indexed-ascii-forms ()
  (let* ((record (heroiclands-goto-test--record
                  "a-none-lore-isle" "lore-isle" "Isle of Ægir" '("Þorn's Refuge")))
         (record (plist-put record :nameAscii "Isle of Aegir"))
         (record (plist-put record :formsAscii (list :en ["Thorn's Refuge"])))
         (index (heroiclands-goto-test--index record)))
    (dolist (query '("aegir" "ÆGIR" "thorn" "ÞORN"))
      (heroiclands-goto-test--closing (format "[[%s]]" query) index
        (heroiclands-goto--close-link)
        (should (equal (buffer-string) "[[lore-isle|Isle of Ægir]]"))))
    (heroiclands-goto-test--closing "[[Thorn's Refuge]]" index
      (heroiclands-goto--close-link)
      (should (equal (buffer-string) "[[lore-isle|Þorn's Refuge]]")))))

(ert-deftest heroiclands-goto-matches-every-language-list ()
  (let* ((record (heroiclands-goto-test--record
                  "a-none-lore-city" "lore-city" "Old Harbour"
                  '(:en ["Port Reach"] :vy ["Vethrun"] :sort "Harbour")))
         (record (plist-put record :formsAscii (list :vy ["Vethrun"])))
         (index (heroiclands-goto-test--index record)))
    (should (equal '("Port Reach" "Vethrun")
                   (heroiclands-goto--name-forms (plist-get record :name))))
    (dolist (query '("Vethrun" "vethr"))
      (should (= 1 (length (heroiclands-goto--name-matches query index)))))
    (should-not (heroiclands-goto--name-matches "Harbour Sort" index))))

(ert-deftest heroiclands-goto-direct-canonical-address-survives-slug-collision ()
  (let* ((foreign (heroiclands-goto-test--record
                   "a-none-lore-town" "lore-town" "Foreign Town"))
         (local (heroiclands-goto-test--record
                 "b-none-lore-town" "lore-town" "Local Town"))
         (index (heroiclands-goto-test--index foreign local)))
    (heroiclands-goto-test--closing "[[a-none-lore-town#dossier]]" index
      (heroiclands-goto--close-link)
      (should (equal (buffer-string)
                     "[[a-none-lore-town#dossier|Foreign Town]]")))))

(defmacro heroiclands-goto-test--published-index (&rest body)
  "Run BODY with a serialized published index FILE under ROOT."
  (declare (indent 0))
  `(let* ((root (make-temp-file "heroiclands-published-index-" t))
          (file (expand-file-name "metadata.jsonl" root))
          (heroiclands-goto--cache nil))
     (unwind-protect
         (progn
           (with-temp-file file
             (dolist (case '(("alpha" "Amber City") ("beta" "Amber Harbor")))
               (let* ((canonical (concat "test-note-lore-" (car case)))
                      (record (heroiclands-goto-test--record
                               canonical (concat "lore-" (car case)) (cadr case))))
                 ;; package-build 23.10's published Address object shape.
                 (setf (plist-get (plist-get record :address) :canonical)
                       (list :address canonical :anchor nil :anchorKind nil))
                 (setf (plist-get record :anchors)
                       (vector (list :slug "history" :name "History" :line 7 :kind "prose"
                                     :link (list :address canonical :anchor "history"
                                                 :anchorKind "prose"))))
                 (setf (plist-get record :documentation)
                       (list :address canonical :anchor "history" :anchorKind "prose"))
                 (insert (json-encode record) "\n"))))
           ,@body)
       (delete-directory root t))))

(ert-deftest heroiclands-goto-reads-published-address-fields ()
  (heroiclands-goto-test--published-index
    (let* ((index (heroiclands-goto--index (list file)))
           (table (plist-get index :table))
           (record (gethash "test-note-lore-alpha" table))
           (anchor (and record (aref (plist-get record :anchors) 0))))
      (should record)
      (should (eq record (gethash "lore-alpha" table)))
      (should (equal (plist-get record :owner-index) file))
      (should (equal (plist-get (plist-get record :address) :canonical)
                     "test-note-lore-alpha"))
      (should (equal (plist-get anchor :link) "test-note-lore-alpha#history"))
      (should (equal (plist-get anchor :kind) "prose"))
      (should (equal (plist-get record :documentation) "test-note-lore-alpha#history")))))

(ert-deftest heroiclands-goto-published-index-closes-names-and-chooses-identity ()
  (heroiclands-goto-test--published-index
    (let ((index (heroiclands-goto--index (list file))))
      (dolist (target '("test-note-lore-alpha" "lore-alpha" "City"))
        (heroiclands-goto-test--closing (format "[[%s#history]]" target) index
          (heroiclands-goto--close-link)
          (should (equal (buffer-string) "[[lore-alpha#history|Amber City]]"))))
      (heroiclands-goto-test--closing "[[Amber#history]]" index
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt choices &rest _)
                     (should (equal (mapcar #'car choices)
                                    '("Amber City — test-note-lore-alpha"
                                      "Amber Harbor — test-note-lore-beta")))
                     "Amber Harbor — test-note-lore-beta")))
          (heroiclands-goto--close-link))
        (should (equal (buffer-string) "[[lore-beta#history|Amber Harbor]]"))))))

(ert-deftest heroiclands-goto-published-index-follows-canonical-anchor ()
  (heroiclands-goto-test--published-index
    (with-temp-buffer
      (insert "[[test-note-lore-alpha#history]]")
      (goto-char 5)
      (let (opened)
        (cl-letf (((symbol-function 'heroiclands-index--root) (lambda () root))
                  ((symbol-function 'heroiclands-index-sources)
                   (lambda (_) (list (cons file root))))
                  ((symbol-function 'heroiclands-goto--content-dir) (lambda (_) "notes"))
                  ((symbol-function 'xref-push-marker-stack) #'ignore)
                  ((symbol-function 'recenter) #'ignore)
                  ((symbol-function 'find-file)
                   (lambda (path)
                     (setq opened path)
                     (erase-buffer)
                     (insert "1\n2\n3\n4\n5\n6\n# History {#history}\n"))))
          (heroiclands-goto-follow))
        (should (equal opened (expand-file-name "notes/Shared.md" root)))
        (should (= (line-number-at-pos) 7))))))

;;; heroiclands-goto-test.el ends here
