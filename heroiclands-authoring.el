;;; heroiclands-authoring.el --- Insert note markup -*- lexical-binding: t; -*-
;; Author: Tom Rodriguez <tom@toastysailor.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Optional editing commands for content notes.  Load with
;; (require 'heroiclands-authoring).  Markdown mode is optional.

;;; Code:
(require 'heroiclands)
(require 'heroiclands-goto)
(require 'subr-x)
(require 'cl-lib)

(declare-function markdown-inline-code-at-point-p "markdown-mode")

(defconst heroiclands-authoring-commands
  '(("s" . heroiclands-insert-span)
    ("u" . heroiclands-insert-url-link)
    ("w" . heroiclands-insert-wikilink)
    ("a" . heroiclands-insert-alert-fence)
    ("x" . heroiclands-insert-secret-fence)
    ("f" . heroiclands-insert-footnote))
  "Local prefix keys and commands, in the order used by the authoring guide.")

(defvar heroiclands-authoring-prefix-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map heroiclands-prefix-map)
    (dolist (entry heroiclands-authoring-commands)
      (define-key map (kbd (car entry)) (cdr entry)))
    map)
  "Authoring keys inheriting the global constellation commands.")
(define-key heroiclands-mode-map (kbd "C-c h") heroiclands-authoring-prefix-map)

(defmacro heroiclands-authoring--change (&rest body)
  "Run BODY as one undoable edit."
  (declare (indent 0) (debug t))
  `(progn
     (undo-boundary)
     (prog1 (atomic-change-group ,@body)
       (deactivate-mark)
       (undo-boundary))))

(defun heroiclands-authoring--inline (kind)
  "Insert an inline wrapper of KIND, preserving selected text properties."
  (let* ((active (use-region-p))
         (beg (if active (region-beginning) (point)))
         (end (if active (region-end) (point)))
         (text (buffer-substring beg end)))
    (when (and (eq kind 'wiki) (string-match-p "]" text))
      (user-error "Wikilink display text cannot contain a closing bracket"))
    (when (string-match-p "\n" text)
      (user-error "Inline markup cannot contain a line break"))
    (heroiclands-authoring--change
     (delete-region beg end)
     (goto-char beg)
     (pcase kind
       ('span
        (insert "[" text "]{}")
        (goto-char (if active (+ beg (length text) 3) (1+ beg))))
       ('url
        (insert "[" text "]()")
        (goto-char (if active (+ beg (length text) 3) (1+ beg))))
       ('wiki
        (insert "[[|" text "]]")
        (goto-char (+ beg 2))
        ;; Explicit insertion does not run `post-self-insert-hook'.  Arm
        ;; exactly as typing the second bracket does, before the label.
        (let ((last-command-event ?\[))
          (heroiclands-goto--arm)))))))

;;;###autoload
(defun heroiclands-insert-span ()
  "Wrap the selection in a span and edit its attributes.
Without a selection, edit the text in []{}.  Multiline selections are
rejected.  The selected text and its formatting are preserved.
See Info node `(heroiclands)Authoring Markup'."
  (interactive)
  (heroiclands-authoring--inline 'span))

;;;###autoload
(defun heroiclands-insert-url-link ()
  "Wrap the selection in a URL link and edit its destination.
Without a selection, edit the label in []().  Multiline selections are
rejected.  The selected text and its formatting are preserved.
See Info node `(heroiclands)Authoring Markup'."
  (interactive)
  (heroiclands-authoring--inline 'url))

;;;###autoload
(defun heroiclands-insert-wikilink ()
  "Insert a wikilink, using the selection as its exact display text.
Point edits the target in [[|label]], with normal server completion.
An empty label is retained so the renderer can choose the display text.
Multiline selections and display text containing ] are rejected.
See Info node `(heroiclands)Authoring Markup'."
  (interactive)
  (heroiclands-authoring--inline 'wiki))

(defun heroiclands-authoring--line-region ()
  "Return the selected whole lines, excluding the final newline.
A selection ending at the start of a line does not include that line."
  (when (use-region-p)
    (let ((beg (region-beginning)) (end (region-end)))
      (cons (save-excursion (goto-char beg) (line-beginning-position))
            (save-excursion
              (goto-char end)
              (when (and (> end beg) (bolp)) (backward-char))
              (line-end-position))))))

(defun heroiclands-authoring--padding (backward)
  "Newlines needed for a paragraph boundary in direction BACKWARD."
  (save-excursion
    (let ((start (point)))
      (if backward (skip-chars-backward "\n") (skip-chars-forward "\n"))
      (if (if backward (bobp) (eobp)) ""
        (make-string (max 0 (- 2 (abs (- (point) start)))) ?\n)))))

(defun heroiclands-authoring--secret-overlap-p (beg end)
  "Whether wrapping BEG through END would nest a secret block."
  (save-restriction
    (widen)
    (let ((mask (heroiclands-authoring--literal-mask))
          (offset 0) (stack nil) (overlap nil))
      (while (and (string-match "^[ \t]*:::\\([^\n]*\\)" mask offset)
                  (< (1+ (match-beginning 0)) end))
        (let ((next (match-end 0))
              (at (1+ (match-beginning 0)))
              (name (car (split-string (string-trim (match-string 1 mask)) "[ \t]+"))))
          (when (and (>= at beg) (or (member "secret" stack) (equal name "secret")))
            (setq overlap t))
          (if (or (null name) (string-empty-p name)) (pop stack) (push name stack))
          (setq offset next)))
      (or overlap (member "secret" stack)))))

(defun heroiclands-authoring--block (type)
  "Insert a secret or alert block of TYPE, expanding selection to lines."
  (let* ((region (heroiclands-authoring--line-region))
         (beg (if region (car region) (point)))
         (end (if region (cdr region) (point)))
         (text (buffer-substring beg end))
         (secret (equal type "secret"))
         (body (if secret
                   (concat ":::secret\n" (if region (concat "\n" text) "")
                           ;; Markdown quotes absorb the closer without a
                           ;; separating blank line, including nested alerts.
                           (if (and region
                                    (string-match-p "^[ \t]*>" (car (last (split-string text "\n")))))
                               "\n\n:::" "\n:::"))
                 (concat "> [!" (upcase type) "]\n"
                         (if region
                             (concat (mapconcat
                                      (lambda (line) (if (string-empty-p line) ">" (concat "> " line)))
                                      (split-string text "\n") "\n") "\n") "")
                         "> "))))
    (when (and secret (heroiclands-authoring--secret-overlap-p beg end))
      (user-error "A secret block cannot contain another secret block"))
    (heroiclands-authoring--change
     (delete-region beg end)
     (goto-char beg)
     (let* ((before (heroiclands-authoring--padding t))
            (after (heroiclands-authoring--padding nil))
            (offset (if secret (length ":::secret\n") (length body))))
       (insert before body after)
       (goto-char (+ beg (length before) offset))))))

;;;###autoload
(defun heroiclands-insert-alert-fence (type)
  "Insert a TYPE alert, quoting the selected whole lines when active.
TYPE is note, tip, important or warning.  Prompt with completion when
called interactively.  Point starts an empty quoted body line.
See Info node `(heroiclands)Authoring Markup'."
  (interactive (list (completing-read "Alert type: " '("note" "tip" "important" "warning") nil t)))
  (unless (member type '("note" "tip" "important" "warning"))
    (user-error "Unknown alert type: %s" type))
  (heroiclands-authoring--block type))

;;;###autoload
(defun heroiclands-insert-secret-fence ()
  "Insert a secret block and edit its first body line.
An active selection expands to whole lines, after an empty first body
line.  Surround the block with paragraph boundaries.  Reject wrapping
or inserting inside an existing secret, since secrets cannot nest.
See Info node `(heroiclands)Authoring Markup'."
  (interactive)
  (heroiclands-authoring--block "secret"))

(defun heroiclands-authoring--escaped-p (text offset)
  "Whether TEXT at zero-based OFFSET follows an odd run of backslashes."
  (let ((count 0))
    (while (and (> offset 0) (= (aref text (1- offset)) ?\\))
      (setq offset (1- offset) count (1+ count)))
    (= (% count 2) 1)))

(defun heroiclands-authoring--indent-width (text)
  "Columns occupied by TEXT, with Markdown's four-column tab stops."
  (let ((column 0))
    (dolist (char (string-to-list text))
      (setq column (+ column (if (= char ?\t) (- 4 (% column 4)) 1))))
    column))

(defun heroiclands-authoring--literal-mask ()
  "Return a string with literal source ranges replaced by spaces.
Positions correspond to the widened buffer.  Recognize YAML frontmatter,
fenced and indented code, backtick spans and HTML comments without a
Markdown dependency.  Newlines are kept to preserve line boundaries."
  (let ((source (buffer-substring-no-properties (point-min) (point-max))))
    (with-temp-buffer
      (insert source)
      (let ((mask (copy-sequence source)) (fence nil) (yaml nil)
            (list-indents nil) (list-gap nil))
        (cl-labels ((hide (beg end)
                      (put-text-property (1- beg) (1- end) 'heroiclands-literal t mask)
                      (dotimes (i (- end beg))
			(unless (= (aref mask (+ (1- beg) i)) ?\n)
                          (aset mask (+ (1- beg) i) ?\s)))))
          (goto-char (point-min))
          (setq yaml (looking-at-p "---[ \t]*$"))
          (while (not (eobp))
            (let* ((beg (line-beginning-position))
                   (end (line-end-position))
                   (line (buffer-substring-no-properties beg end))
                   ;; Quote prefixes can enclose code examples as well.
                   (unquoted (replace-regexp-in-string "\\`\\(?:[ \t]*>[ \t]?\\)+" "" line)))
              ;; List continuation indentation is prose until four columns
              ;; beyond the content column; nested items establish a new one.
              (when (not fence)
                (cond
                 ((string-match-p "\\`[ ]\\{0,3\\}\\[\\^[^]]+\\]:" unquoted)
                  (setq list-indents '(4) list-gap nil))
                 ((string-match "\\`[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\)[ \t]+" unquoted)
                  (let ((column (heroiclands-authoring--indent-width (match-string 0 unquoted))))
                    (while (and list-indents (>= (car list-indents) column))
                      (pop list-indents))
                    (push column list-indents))
                  (setq list-gap nil))
                 ((string-empty-p (string-trim unquoted)) (setq list-gap t))
                 ((and list-gap (not (string-match-p "\\`[ \t]+" unquoted)))
                  (setq list-indents nil list-gap nil))))
              (cond
               (yaml
                (hide beg end)
                (when (and (> beg 1) (string-match-p "\\`\\(?:---\\|\\.\\.\\.\\)[ \t]*\\'" line))
                  (setq yaml nil)))
               (fence
                (unless (nth 2 fence) (hide beg end))
                (when (string-match-p (concat "\\`[ \t]*" (regexp-quote (nth 0 fence))
                                              "\\{" (number-to-string (nth 1 fence)) ",\\}[ \t]*\\'") unquoted)
                  (when (nth 2 fence)
                    (put-text-property (1- (nth 3 fence)) (1- end)
                                       'heroiclands-poetry-end end mask)
                    (when (nth 4 fence)
                      (put-text-property (1- (nth 3 fence)) (1- end)
                                         'heroiclands-nested-poetry t mask))
                    (hide beg end))
                  (setq fence nil)))
               ((string-match "\\`[ ]\\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)" unquoted)
                (let ((run (match-string 1 unquoted)))
                  (setq fence (list (substring run 0 1) (length run)
                                    (string-match-p "\\`[ ]\\{0,3\\}[`~]+poetry\\(?:[ \t]\\|\\'\\)" unquoted)
                                    beg (or list-indents (not (equal line unquoted))))))
                (hide beg end))
               ((string-match "\\`[ \t]+" unquoted)
                (let ((indent (heroiclands-authoring--indent-width (match-string 0 unquoted))))
                  (while (and (cdr list-indents) (< indent (car list-indents)))
                    (pop list-indents))
                  (when (>= indent (+ 4 (or (car list-indents) 0)))
                    (hide beg end))))))
            (forward-line 1))
          (when (and fence (nth 2 fence))
            (put-text-property (1- (nth 3 fence)) (length mask)
                               'heroiclands-unclosed-poetry t mask))
          ;; Scan the block-masked text so comment and code delimiters
          ;; inside fenced code cannot leak out and hide ordinary prose.
          (erase-buffer)
          (insert mask)
          (goto-char (point-min))
          (while (re-search-forward "<!--\\|`+" nil t)
            (let ((beg (match-beginning 0)) (token (match-string 0)))
              (unless (heroiclands-authoring--escaped-p mask (1- beg))
                (if (equal token "<!--")
                    (hide beg (if (search-forward "-->" nil t) (point) (point-max)))
                  (let ((size (length token)) (end nil))
                    (save-excursion
                      (while (and (not end) (re-search-forward "`+" nil t))
			(when (= (- (match-end 0) (match-beginning 0)) size)
                          (setq end (point)))))
                    (when end (hide beg end) (goto-char end)))))))
          mask)))))

(defun heroiclands-authoring--quote-start ()
  "Find the quote containing this line, including a lazy continuation."
  (save-excursion
    (beginning-of-line)
    (let ((found nil) (done nil))
      (while (not done)
        (cond
         ((looking-at-p "[ \t]*>") (setq found (point) done t))
         ((or (bobp) (looking-at-p "[ \t]*$")
              (looking-at-p "[ \t]*[#|`~]")) (setq done t))
         (t (forward-line -1))))
      found)))

(defun heroiclands-authoring--paragraph-end (mask)
  "Move to a safe top-level definition position after this block.
MASK records poetry fences.  Lists and quotes include their continuation
paragraphs so the definition cannot become part of the enclosing block."
  (let ((poetry (get-text-property (1- (point)) 'heroiclands-poetry-end mask))
        (quote-start (heroiclands-authoring--quote-start)))
    (cond
     (poetry (goto-char poetry))
     (quote-start
      (goto-char quote-start)
      (let ((gap nil) (last-end (line-end-position)) (done nil))
        (while (and (not done) (not (eobp)))
          (cond
           ((looking-at-p "[ \t]*>")
            (setq gap (looking-at-p "[ \t]*>[ \t]*$")
                  last-end (line-end-position)))
           ((looking-at-p "[ \t]*$")
            (if (save-excursion (skip-chars-forward " \t\n") (looking-at-p ">"))
                (setq gap t)
              (setq done t)))
           ((or gap (looking-at-p "[ \t]*[#|`~]")) (setq done t))
           (t (setq last-end (line-end-position))))
          (unless done (forward-line 1)))
        (goto-char last-end)))
     (t
      (let ((list-start nil) (origin (point))
            (item "[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\)[ \t]+"))
        (save-excursion
          (beginning-of-line)
          (when (looking-at-p item) (setq list-start (point)))
          (while (and (not (bobp))
                      (or (looking-at-p item) (looking-at-p "[ \t]+\\|[ \t]*$")))
            (forward-line -1)
            (when (looking-at-p item) (setq list-start (point)))))
        (if list-start
            (let ((gap nil) (last-end nil) (done nil))
              (goto-char list-start)
              (while (and (not done) (not (eobp)))
                (cond
                 ((looking-at-p "[ \t]*$") (setq gap t))
                 ((or (looking-at-p item) (looking-at-p "[ \t]+"))
                  (setq last-end (line-end-position) gap nil))
                 ((or gap (looking-at-p "[#>|`~]")) (setq done t))
                 (t (setq last-end (line-end-position))))
                (unless done (forward-line 1)))
              (goto-char (max origin (or last-end origin))))
          (beginning-of-line)
          (cond
           ((looking-at-p "[ \t]*#") (end-of-line))
           ((looking-at-p "[ \t]*|")
            (while (and (not (eobp)) (looking-at-p "[ \t]*|")) (forward-line 1))
            (when (bolp) (backward-char))
            (end-of-line))
           (t
            (end-of-line)
            (while (and (not (eobp))
                        (save-excursion
                          (forward-line 1)
                          (not (or (looking-at-p "[ \t]*$")
                                   (looking-at-p "[ \t]*[#>|`~]")
                                   (looking-at-p item)))))
              (forward-line 1) (end-of-line))))))))))

;;;###autoload
(defun heroiclands-insert-footnote ()
  "Insert a fresh numeric footnote after the word at point.
Use the smallest unused positive number in the entire note, ignoring
literal code, HTML comments and YAML frontmatter.  Existing references
beside the word precede the new reference; punctuation follows it.
On whitespace or punctuation, insert exactly at point.  The definition
starts the next top-level paragraph after the current paragraph, with
point ready for its text.  Literal contexts, unclosed poetry fences and
positions within wikilinks, footnote definitions and nested poetry are
rejected.  Widen when the definition would otherwise lie outside the
accessible restriction.
See Info node `(heroiclands)Authoring Markup'."
  (interactive)
  (let ((origin (point)) mask id destination)
    (save-restriction
      (widen)
      (when (save-excursion
              (beginning-of-line)
              (or (looking-at-p "[ ]\\{0,3\\}\\[\\^[^]]+\\]:")
                  (and (looking-at-p "[ \t]+")
                       (progn
                         (while (and (not (bobp)) (looking-at-p "[ \t]+\\|[ \t]*$"))
                           (forward-line -1))
                         (looking-at-p "[ ]\\{0,3\\}\\[\\^[^]]+\\]:")))))
        (user-error "Move outside the footnote definition before adding a footnote"))
      (when (and (heroiclands-goto-link-at-point)
                 (not (and (>= origin (+ (point-min) 2))
                           (equal "]]" (buffer-substring-no-properties (- origin 2) origin)))))
        (user-error "Move outside the wikilink before adding a footnote"))
      (setq mask (heroiclands-authoring--literal-mask))
      (when (or (get-text-property (1- origin) 'heroiclands-nested-poetry mask)
                (and (> origin 1)
                     (get-text-property (- origin 2) 'heroiclands-nested-poetry mask)))
        (user-error "Move outside nested poetry before adding a footnote"))
      (when (or (get-text-property (1- origin) 'heroiclands-unclosed-poetry mask)
                (and (> origin 1)
                     (get-text-property (- origin 2) 'heroiclands-unclosed-poetry mask)))
        (user-error "Close the poetry fence before adding a footnote"))
      (when (or (and (< origin (point-max))
                     (get-text-property (1- origin) 'heroiclands-literal mask))
                (and (> origin (point-min))
                     (memq (char-syntax (char-before origin)) '(?w ?_))
                     (get-text-property (- origin 2) 'heroiclands-literal mask))
                (and (derived-mode-p 'markdown-mode)
                     (fboundp 'markdown-inline-code-at-point-p)
                     (markdown-inline-code-at-point-p)))
        (user-error "Footnotes cannot be inserted in literal markup"))
      (let ((used (make-hash-table :test #'eql)) (start 0))
        (while (string-match "\\[\\^\\([0-9]+\\)\\]" mask start)
          (unless (heroiclands-authoring--escaped-p mask (match-beginning 0))
            (puthash (string-to-number (match-string 1 mask)) t used))
          (setq start (match-end 0)))
        (setq id 1)
        (while (gethash id used) (setq id (1+ id))))
      (setq destination (copy-marker
                         (save-excursion
                           (goto-char origin)
                           (heroiclands-authoring--paragraph-end mask)
                           (point)) t))
      (heroiclands-authoring--change
       (goto-char origin)
       (when (or (memq (char-syntax (or (char-after) ?\s)) '(?w ?_))
                 (and (> (point) (point-min))
                      (memq (char-syntax (char-before)) '(?w ?_))))
         (skip-syntax-forward "w_")
         (while (looking-at "\\[\\^[^]\n]+\\]") (goto-char (match-end 0))))
       (insert (format "[^%d]" id))
       (goto-char destination)
       (set-marker destination nil)
       (let ((after (heroiclands-authoring--padding nil)))
         (insert (format "\n\n[^%d]: " id))
         (setq destination (point))
         (insert after)
         (goto-char destination))))
    ;; Preserve narrowing when possible.  Otherwise exposing the destination
    ;; is necessary for the promised editing position to remain accessible.
    (unless (<= (point-min) destination (point-max)) (widen))
    (goto-char destination)))

(provide 'heroiclands-authoring)
;;; heroiclands-authoring.el ends here
