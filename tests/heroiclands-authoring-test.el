;;; heroiclands-authoring-test.el --- Authoring checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'heroiclands-eglot)
(require 'heroiclands-authoring nil t)

(defmacro heroiclands-authoring-test--buffer (text &rest body)
  (declare (indent 1))
  `(with-temp-buffer
     (text-mode)
     (buffer-enable-undo)
     (insert ,text)
     (goto-char (point-min))
     (setq buffer-undo-list nil)
     ,@body))

(ert-deftest heroiclands-authoring-registry-docstrings-and-local-keys ()
  (let ((registered (mapcar #'cdr heroiclands-authoring-commands)) (public nil))
    (mapatoms (lambda (symbol)
                (when (and (string-prefix-p "heroiclands-insert-" (symbol-name symbol))
                           (commandp symbol))
                  (push symbol public))))
    (should (= (length registered) 6))
    (should (equal (sort registered #'string<) (sort public #'string<))))
  (dolist (entry heroiclands-authoring-commands)
    (let ((command (cdr entry)))
      (should (commandp command))
      (should (string-suffix-p "See Info node `(heroiclands)Authoring Markup'."
                               (car (split-string (documentation command t) "\n\n(fn "))))
      (should (eq (lookup-key heroiclands-mode-map (kbd (concat "C-c h " (car entry))))
                  command))))
  (heroiclands-authoring-test--buffer ""
    (let ((heroiclands-mode t))
      (should (eq (key-binding (kbd "C-c h f")) #'heroiclands-insert-footnote))
      (should (eq (key-binding (kbd "C-c h g")) #'heroiclands-ripgrep-all)))
    (let ((heroiclands-mode nil))
      (should (eq (key-binding (kbd "C-c h f")) #'heroiclands-find-note)))))

(ert-deftest heroiclands-authoring-inline-empty-and-selected ()
  (dolist (case '((heroiclands-insert-span "[]{}" 2 "[Ém *Dash*]{}" 13)
                  (heroiclands-insert-url-link "[]()" 2 "[Ém *Dash*]()" 13)
                  (heroiclands-insert-wikilink "[[|]]" 3 "[[|Ém *Dash*]]" 3)))
    (heroiclands-authoring-test--buffer ""
      (electric-pair-mode 1)
      (funcall (car case))
      (should (equal (buffer-string) (nth 1 case)))
      (should (= (point) (nth 2 case))))
    (dolist (reverse '(nil t))
      (heroiclands-authoring-test--buffer (propertize "Ém *Dash*" 'face 'bold)
	(transient-mark-mode 1)
	(goto-char (if reverse (point-min) (point-max)))
	(set-mark (if reverse (point-max) (point-min)))
	(activate-mark)
	(funcall (car case))
	(should (equal (buffer-string) (nth 3 case)))
	(should (= (point) (nth 4 case)))
	(should (text-property-any (point-min) (point-max) 'face 'bold))
	(undo 1)
	(should (equal (buffer-string) "Ém *Dash*"))))))

(ert-deftest heroiclands-authoring-inline-rejects-multiline-unchanged ()
  (dolist (command '(heroiclands-insert-span heroiclands-insert-url-link heroiclands-insert-wikilink))
    (heroiclands-authoring-test--buffer "one\ntwo"
      (transient-mark-mode 1)
      (set-mark (point-max))
      (activate-mark)
      (should-error (funcall command) :type 'user-error)
      (should (equal (buffer-string) "one\ntwo")))))

(ert-deftest heroiclands-authoring-wikilink-capf-preserves-labels-and-anchors ()
  (dolist (label '("" "Ém *Dash*"))
    (dolist (anchor '("" "#dossier"))
      (heroiclands-authoring-test--buffer label
	(when (not (string-empty-p label))
	  (transient-mark-mode 1)
	  (set-mark (point-max))
	  (activate-mark))
	(heroiclands-insert-wikilink)
	(insert "au")
	(let* ((address (concat "being-aurochs" anchor))
	       (item `(:textEdit (:newText ,address)
				 :data (:address "thalorna-being-aurochs" :display "Aurochs")))
	       (candidate (propertize "Aurochs" 'eglot--lsp-item item)))
	  (cl-letf (((symbol-function 'heroiclands-eglot--content-buffer-p) (lambda () t))
		    ((symbol-function 'eglot-managed-p) (lambda () t))
		    ((symbol-function 'eglot-completion-at-point)
		     (lambda ()
		       (list 3 (point) (list candidate) :exit-function
			     (lambda (_candidate _status)
			       (delete-region 3 (point))
			       (insert address))))))
	    (let ((capf (heroiclands-eglot-capf)))
	      (should capf)
	      (funcall (plist-get (nthcdr 3 capf) :exit-function) candidate 'finished)
	      (should (equal (buffer-string) (format "[[%s|%s]]" address label)))
	      (should-not heroiclands-goto--entry)
	      (should-not heroiclands-goto--selected))))))))

(ert-deftest heroiclands-authoring-alert-prompts-and-validates ()
  (heroiclands-authoring-test--buffer ""
    (cl-letf (((symbol-function 'completing-read)
	       (lambda (_prompt choices _predicate require-match &rest _)
		 (should (equal choices '("note" "tip" "important" "warning")))
		 (should require-match)
		 "warning")))
      (call-interactively #'heroiclands-insert-alert-fence))
    (should (equal (buffer-string) "> [!WARNING]\n> "))
    (should (= (point) (point-max))))
  (heroiclands-authoring-test--buffer "unchanged"
    (should-error (heroiclands-insert-alert-fence "bad") :type 'user-error)
    (should (equal (buffer-string) "unchanged"))))

(ert-deftest heroiclands-authoring-block-selection-and-spacing ()
  (dolist (case '((heroiclands-insert-alert-fence "> [!NOTE]\n> one\n>\n> two\n> ")
                  (heroiclands-insert-secret-fence ":::secret\n\none\n\ntwo\n:::")))
    (heroiclands-authoring-test--buffer "before\n\none\n\ntwo\n\nafter"
      (search-forward "one")
      (transient-mark-mode 1)
      (set-mark (progn (search-forward "two") (point)))
      (search-backward "one")
      (activate-mark)
      (if (eq (car case) 'heroiclands-insert-alert-fence)
	  (funcall (car case) "note")
	(funcall (car case)))
      (should (equal (buffer-string) (concat "before\n\n" (cadr case) "\n\nafter")))
      (undo 1)
      (should (equal (buffer-string) "before\n\none\n\ntwo\n\nafter")))))

(ert-deftest heroiclands-authoring-secret-nested-alert-has-blank-before-close ()
  (heroiclands-authoring-test--buffer "> [!NOTE]\n> body"
    (transient-mark-mode 1)
    (set-mark (point-max)) (activate-mark)
    (heroiclands-insert-secret-fence)
    (should (equal (buffer-string) ":::secret\n\n> [!NOTE]\n> body\n\n:::"))))

(ert-deftest heroiclands-authoring-footnote-numbering-and-paragraph ()
  (heroiclands-authoring-test--buffer "Élan, and more\non next line.\n\nOther[^1] and [^3].\n\n[^name]: named"
    (forward-char 2)
    (heroiclands-insert-footnote)
    (should (equal (buffer-string)
		   "Élan[^2], and more\non next line.\n\n[^2]: \n\nOther[^1] and [^3].\n\n[^name]: named"))
    (should (looking-back "\\[\\^2\\]: " (line-beginning-position)))
    (undo 1)
    (should (equal (buffer-string) "Élan, and more\non next line.\n\nOther[^1] and [^3].\n\n[^name]: named"))))

(ert-deftest heroiclands-authoring-footnote-ignores-literals ()
  (heroiclands-authoring-test--buffer "---\ntitle: '[^1]'\n---\nWord.\n\n`[^1]` ``[^2]`` <!-- [^3] -->\n\n```md\n[^4]\n```\n\n    [^5]\n\n[^2]: real"
    (search-forward "Word")
    (heroiclands-insert-footnote)
    (should (string-match-p "Word\\[\\^1\\]\\." (buffer-string)))))

(ert-deftest heroiclands-authoring-footnote-rejects-literal-context ()
  (dolist (text '("`word`" "<!-- word -->" "```\nword\n```" "    word" "---\nword: value\n---"))
    (heroiclands-authoring-test--buffer text
      (search-forward "word")
      (should-error (heroiclands-insert-footnote) :type 'user-error)
      (should (equal (buffer-string) text)))))

(ert-deftest heroiclands-authoring-footnote-narrowing-and-top-level ()
  (heroiclands-authoring-test--buffer "Outside[^1].\n\n> quoted word.\n> next line\n\nAfter"
    (search-forward "quoted")
    (narrow-to-region (line-beginning-position) (line-end-position))
    (heroiclands-insert-footnote)
    (widen)
    (should (equal (buffer-string) "Outside[^1].\n\n> quoted[^2] word.\n> next line\n\n[^2]: \n\nAfter"))))

(ert-deftest heroiclands-authoring-footnote-existing-reference-and-eof ()
  (heroiclands-authoring-test--buffer "word[^1], rest."
    (forward-char 2)
    (heroiclands-insert-footnote)
    (should (equal (buffer-string) "word[^1][^2], rest.\n\n[^2]: ")))
  (heroiclands-authoring-test--buffer "!"
    (heroiclands-insert-footnote)
    (should (equal (buffer-string) "[^1]!\n\n[^1]: "))))

(ert-deftest heroiclands-authoring-alert-kinds-cursors-and-undo ()
  (dolist (kind '("note" "tip" "important" "warning"))
    (dolist (selected '(nil t))
      (heroiclands-authoring-test--buffer (if selected "one\ntwo\nafter" "")
	(when selected
	  (transient-mark-mode 1)
	  (set-mark (progn (forward-line 2) (point)))
	  (goto-char (point-min)) (activate-mark))
	(heroiclands-insert-alert-fence kind)
	(should (equal (buffer-string)
		       (concat "> [!" (upcase kind) "]\n"
			       (if selected "> one\n> two\n> \n\nafter" "> "))))
	(should (looking-back "^> " (line-beginning-position)))
	(should (eolp))
	(undo 1)
	(should (equal (buffer-string) (if selected "one\ntwo\nafter" "")))))))

(ert-deftest heroiclands-authoring-secret-cursors-and-whole-lines ()
  (dolist (selected '(nil t))
    (heroiclands-authoring-test--buffer (if selected "before\nline one\nline two\nafter" "")
      (when selected
	(search-forward "one")
	(transient-mark-mode 1)
	(set-mark (progn (search-forward "two") (point)))
	(search-backward "one") (activate-mark))
      (heroiclands-insert-secret-fence)
      (should (equal (buffer-string)
		     (if selected "before\n\n:::secret\n\nline one\nline two\n:::\n\nafter"
		       ":::secret\n\n:::")))
      (should (bolp))
      (should (eolp))
      (should (equal (save-excursion (forward-line -1)
				     (buffer-substring (line-beginning-position) (line-end-position)))
		     ":::secret")))))

(ert-deftest heroiclands-authoring-footnote-live-literal-and-escaped-numbering ()
  (dolist (case '(("- item\n\n    continuation[^1]\n\nWord." 2)
                  ("[^name]: text\n\n    continuation[^1]\n\nWord." 2)
                  ("Word.\n\n\\`literal[^1]\\`" 2)
                  ("Word.\n\n\\[^1]" 1)
                  ("Word.\n\n\\\\[^1]" 2)
                  ("Word.\n\n<!-- ` [^1] -->" 1)
                  ("Word.\n\n``inline ` [^1]``" 1)
                  ("Word.\n\n~~~md\n[^1]\n~~~" 1)))
    (heroiclands-authoring-test--buffer (car case)
      (search-forward "Word")
      (heroiclands-insert-footnote)
      (should (string-match-p (regexp-quote (format "Word[^%d]." (cadr case))) (buffer-string))))))

(ert-deftest heroiclands-authoring-footnote-container-boundaries ()
  (dolist (block '("- word[^1]\n- second\n  - nested\n\n    continuation"
                   "> word[^1]\n>\n> second"
                   "| word[^1] | value |\n| --- | --- |\n| next | row |"
                   "# word[^1]"
                   "```poetry {form=ballad}\nword[^1]\n\n    second verse\n```"))
    (dolist (gap '("\n\n" "\n"))
      (let ((following (if (equal gap "\n") "# After." "After.")))
	(heroiclands-authoring-test--buffer (concat block gap following)
	  (search-forward "word")
	  (heroiclands-insert-footnote)
	  (should (equal (buffer-string)
			 (concat (replace-regexp-in-string "word\\[\\^1\\]" "word[^1][^2]" block t t)
				 "\n\n[^2]: \n\n" following))))))))

(ert-deftest heroiclands-authoring-footnote-poetry-numbering-and-unclosed-fence ()
  (heroiclands-authoring-test--buffer "Word.\n\n```poetry\n    verse[^1]\n```"
    (search-forward "Word")
    (heroiclands-insert-footnote)
    (should (string-prefix-p "Word[^2]." (buffer-string))))
  (heroiclands-authoring-test--buffer "```poetry\nword"
    (search-forward "word")
    (should-error (heroiclands-insert-footnote) :type 'user-error)
    (should (equal (buffer-string) "```poetry\nword"))))

(ert-deftest heroiclands-authoring-rejects-invalid-wikilink-contexts ()
  (heroiclands-authoring-test--buffer "the [Watch]{.name}"
    (transient-mark-mode 1) (set-mark (point-max)) (activate-mark)
    (should-error (heroiclands-insert-wikilink) :type 'user-error)
    (should (equal (buffer-string) "the [Watch]{.name}")))
  (heroiclands-authoring-test--buffer "[[lore-town|word]]"
    (search-forward "word")
    (should-error (heroiclands-insert-footnote) :type 'user-error)
    (should (equal (buffer-string) "[[lore-town|word]]"))))

(ert-deftest heroiclands-authoring-footnote-lazy-quote-and-definition-context ()
  (heroiclands-authoring-test--buffer "> quoted word\nlazy continuation\n\nAfter"
    (search-forward "word") (heroiclands-insert-footnote)
    (should (equal (buffer-string) "> quoted word[^1]\nlazy continuation\n\n[^1]: \n\nAfter")))
  (dolist (text '("[^old]: first word\n\n    continued footnote text\n\nAfter"
                  "```poetry\nword\n```"))
    (heroiclands-authoring-test--buffer (if (string-prefix-p "```" text) (concat "> " (replace-regexp-in-string "\n" "\n> " text)) text)
      (let ((original (buffer-string)))
	(search-forward "word")
	(should-error (heroiclands-insert-footnote) :type 'user-error)
	(should (equal (buffer-string) original))))))

(ert-deftest heroiclands-authoring-real-markdown-smoke ()
  (skip-unless (require 'markdown-mode nil t))
  (dolist (case '(("Élan, rest.\n\nAfter" "Élan[^1], rest.\n\n[^1]: \n\nAfter")
                  ("```poetry {form=ballad}\nÉlan\n\n    verse\n```" "```poetry {form=ballad}\nÉlan[^1]\n\n    verse\n```\n\n[^1]: ")
                  ("- Élan\n\n    continuation[^1]\n\nAfter" "- Élan[^2]\n\n    continuation[^1]\n\n[^2]: \n\nAfter")))
    (with-temp-buffer
      (markdown-mode)
      (insert (car case)) (goto-char (point-min)) (search-forward "Élan")
      (heroiclands-insert-footnote)
      (should (equal (buffer-string) (cadr case)))))
  (with-temp-buffer
    (markdown-mode)
    (electric-pair-local-mode 1)
    (heroiclands-insert-wikilink)
    (should (equal (buffer-string) "[[|]]"))
    (should (heroiclands-goto--armed-p))))

(ert-deftest heroiclands-authoring-secret-rejects-nesting ()
  (dolist (selected '(nil t))
    (heroiclands-authoring-test--buffer ":::secret\nbody\n:::"
      (if selected
	  (progn (transient-mark-mode 1) (set-mark (point-max)) (activate-mark))
	(search-forward "body"))
      (should-error (heroiclands-insert-secret-fence) :type 'user-error)
      (should (equal (buffer-string) ":::secret\nbody\n:::")))))

(ert-deftest heroiclands-authoring-footnote-after-wikilink-is-safe ()
  (heroiclands-authoring-test--buffer "[[lore-town|word]]"
    (goto-char (point-max))
    (heroiclands-insert-footnote)
    (should (equal (buffer-string) "[[lore-town|word]][^1]\n\n[^1]: "))))

(ert-deftest heroiclands-authoring-tab-code-and-generic-div-nesting ()
  (heroiclands-authoring-test--buffer "Word.\n\n\t[^1]"
    (search-forward "Word") (heroiclands-insert-footnote)
    (should (string-prefix-p "Word[^1]." (buffer-string))))
  (heroiclands-authoring-test--buffer ":::secret\n::: {#aside}\nword\n:::\n:::"
    (search-forward "word")
    (should-error (heroiclands-insert-secret-fence) :type 'user-error)
    (should (equal (buffer-string) ":::secret\n::: {#aside}\nword\n:::\n:::"))))

(ert-deftest heroiclands-authoring-footnote-from-lazy-quote-line ()
  (heroiclands-authoring-test--buffer "> [!NOTE]\n> first\nlazy word\n> last\n\nAfter"
    (search-forward "word") (heroiclands-insert-footnote)
    (should (equal (buffer-string) "> [!NOTE]\n> first\nlazy word[^1]\n> last\n\n[^1]: \n\nAfter"))))

(provide 'heroiclands-authoring-test)
