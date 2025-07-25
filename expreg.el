;;; expreg.el --- Simple expand region  -*- lexical-binding: t; -*-

;; Copyright (C) 2022 Free Software Foundation, Inc.
;;
;; Author: Yuan Fu <casouri@gmail.com>
;; Maintainer: Yuan Fu <casouri@gmail.com>
;; URL: https://github.com/casouri/expreg
;; Version: 1.4.1
;; Keywords: text, editing
;; Package-Requires: ((emacs "29.1"))
;;
;; This file is part of GNU Emacs.
;;
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This is just like expand-region, but (1) we generate all regions at
;; once, and (2) should be easier to debug, and (3) we out-source
;; language-specific expansions to tree-sitter. Bind ‘expreg-expand’
;; and ‘expreg-contract’ and start using it.
;;
;; Note that if point is in between two possible regions, we only keep
;; the region after point. In the example below, only region B is kept
;; (“|” represents point):
;;
;;     (region A)|(region B)
;;
;; Expreg also recognizes subwords if ‘subword-mode’ is on.
;;
;; By default, the sentence expander ‘expreg--sentence’ is not
;; enabled. I suggest enabling it (by adding it to ‘expreg-functions’)
;; in text modes only.

;;; TODO
;;
;; - Support list/string in comment.

;;; Developer
;;
;; It works roughly as follows: ‘expreg-expand’ collects a list of
;; possible expansions on startup with functions in
;; ‘expreg-functions’. Then it sorts them by each region’s size. It
;; also removes duplicates, etc. Then this list is stored in
;; ‘expreg--next-regions’. (There could be better sorting algorithms,
;; but so far I haven’t seen the need for one.)
;;
;; To expand, we pop a region from ‘expreg--next-regions’, set point
;; and mark accordingly, and push this region to
;; ‘expreg--prev-regions’. So the head of ‘expreg--prev-regions’
;; should always equal the current region.
;;
;; ‘expreg-contract’ does just the opposite: it pops a region from
;; ‘expreg--prev-regions’, push it to ‘expreg--next-regions’, and set
;; the current region to the head of ‘expreg--prev-regions’.
;;
;; For better debugability, each region is of the form
;;
;;     (FN . (BEG . END))
;;
;; where FN is the function produced this region. So accessing BEG is
;; ‘cadr’, accessing END is ‘cddr’. Sometimes FN is the function name
;; plus some further descriptions, eg, word, word--symbol,
;; word--within-space are all produced by ‘expreg--word’. I use double
;; dash to indicate the additional descriptor.
;;
;; Credit: I stole a lot of ideas on how to expand lists and strings
;; from ‘expand-region’ :-)

;;; Code:

(require 'subword)
(require 'treesit)
(eval-when-compile
  (require 'cl-lib))
(require 'seq)

;;; Custom options and variables

(defvar-local expreg-functions
  '( expreg--subword expreg--word expreg--list expreg--string
     expreg--treesit expreg--comment expreg--paragraph-defun)
  "A list of expansion functions.

Each function is called with no arguments and should return a
list of (BEG . END). The list don’t have to be sorted, and can
have duplicates. It’s also fine to include invalid regions, such
as ones where BEG equals END, etc, they’ll be filtered out by
‘expreg--filter-regions’.

The function could move point, but shouldn’t return any
scan-error, like end-of-buffer, or unbalanced parentheses, etc.")

(defvar expreg-restore-point-on-quit nil
  "If t, restore the point when quitting with ‘keyboard-quit’.

By default, when user presses quit when expanding, nothing special
happens: the region is deactivated and the point stays at where it is.
But if this option is turned on, Emacs moves point back to where it was
when user first started calling ‘expreg-expand’.")

;;; Helper functions

(defun expreg--sort-regions (regions)
  "Sort REGIONS by their span."
  (cl-sort regions (lambda (a b)
                     (< (- (cddr a) (cadr a))
                        (- (cddr b) (cadr b))))))

(defvar expreg--validation-white-list '(list-at-point)
  "Regions produced by functions in this list skips filtering.")

(defun expreg--valid-p (region orig)
  "Return non-nil if REGION = (BEG . END) valid regarding ORIG.
ORIG is the current position."
  (let ((producer (car region))
        (beg (cadr region))
        (end (cddr region)))

    (or (memq producer expreg--validation-white-list)
        (and (<= beg orig end)
             (< beg end)
             ;; We don’t filter out regions that’s only one character
             ;; long, because there are useful regions of that size.
             ;; Consider ‘c-ts-mode--looking-at-star’, the "c" is one
             ;; character long but we don’t want to skip it: my muscle
             ;; remembers to hit C-= twice to mark a symbol, skipping "c"
             ;; messes that up. (ref:single-char-region)
             ;; (< 1 (- end beg) 8000)

             ;; If the region is only one character long, and the
             ;; character is stuff like bracket, escape char, quote, etc,
             ;; filter it out. This is usually returned by
             ;; ‘expreg--treesit’.
             (not (and (eq (- end beg) 1)
                       (not (memq (char-syntax (char-after beg))
                                  '(?- ?w ?_)))))))))

(defun expreg--filter-regions (regions orig)
  "Filter out invalid regions in REGIONS regarding ORIG.
ORIG is the current position. Each region is (BEG . END)."
  (let (orig-at-beg-of-something
        orig-at-end-of-something)

    (setq regions (seq-filter
                   (lambda (region)
                     (expreg--valid-p region orig))
                   regions))

    ;; It is important that this runs after the first filter.
    ;; ‘orig-at-beg/end-of-something’ is t means there are some REGION
    ;; that starts/ends at ORIG.
    (dolist (region regions)
      (when (eq (cadr region) orig)
        (setq orig-at-beg-of-something t))
      (when (eq (cddr region) orig)
        (setq orig-at-end-of-something t)))

    ;; If there are regions that start at ORIG, filter out
    ;; regions that ends at ORIG.
    (setq regions (cl-remove-if
                   (lambda (region)
                     (and orig-at-beg-of-something
                          (eq (cddr region) orig)))
                   regions))

    ;; OTOH, if there are regions that ends at ORIG, filter out
    ;; regions that starts AFTER ORIGN, eg, special cases in
    ;; ‘expreg--list-at-point’.
    (setq regions (cl-remove-if
                   (lambda (region)
                     (and orig-at-end-of-something
                          (> (cadr region) orig)))
                   regions))
    regions))

;;; Syntax-ppss shorthands

(defsubst expreg--inside-comment-p (&optional pos)
  "Test whether POS is inside a comment.
POS defaults to point."
  (nth 4 (syntax-ppss pos)))

(defsubst expreg--inside-string-p ()
  "Test whether point is inside a string."
  (nth 3 (syntax-ppss)))

(defsubst expreg--start-of-comment-or-string ()
  "Start position of enclosing comment/string."
  (nth 8 (syntax-ppss)))

(defsubst expreg--current-depth ()
  "Current list depth."
  (car (syntax-ppss)))

(defsubst expreg--start-of-list ()
  "Start position of innermost list."
  (nth 1 (syntax-ppss)))

;;; Expand/contract

(defvar-local expreg--verbose nil
  "If t, print debugging information.")

(defvar-local expreg--next-regions nil
  "The regions we are going to expand to.
This should be a list of (BEG . END).")

(defvar-local expreg--prev-regions nil
  "The regions we’ve expanded past.
This should be a list of (BEG . END).")

(defvar-local expreg--initial-point nil
  "The point at where the first ‘expreg-expand’ is called.
This is used to restore point when canceling the expansion when
‘expreg-restore-point-on-quit’ is enabled.")

(defun expreg--keyboard-quit-advice ()
  "Restores point when ‘keyboard-quit’ is called."
  (interactive)
  (when (and expreg-restore-point-on-quit expreg--initial-point)
    (goto-char expreg--initial-point))
  (setq expreg--initial-point nil))

;;;###autoload
(defun expreg-expand ()
  "Expand region."
  (interactive)
  ;; Initialize states if this is the first call to expreg functions.
  (when (not (and (use-region-p)
                  (eq (region-beginning)
                      (cadr (car expreg--prev-regions)))
                  (eq (region-end)
                      (cddr (car expreg--prev-regions)))))
    (setq-local expreg--next-regions nil)
    (setq-local expreg--prev-regions nil)
    (setq-local expreg--initial-point (point))
    (when expreg-restore-point-on-quit
      ;; We have to add the advice using :before. :after doesn’t work
      ;; (advice doesn’t get called). ‘set-transient-map’ doesn’t work
      ;; either because of how special ‘keyboard-quit’ is.
      (advice-add 'keyboard-quit :before #'expreg--keyboard-quit-advice)))

  ;; If we are not already in the middle of expansions, compute them.
  (when (and (null expreg--next-regions)
             (null expreg--prev-regions))
    (let* ((orig (point))
           (regions (mapcan (lambda (fn) (save-excursion
                                           (funcall fn)))
                            expreg-functions))
           (regions (expreg--filter-regions regions orig))
           (regions (expreg--sort-regions regions))
           (regions (cl-remove-duplicates regions :test #'equal :key #'cdr)))
      (setq-local expreg--next-regions regions)))

  ;; Go past all the regions that are smaller than the current region,
  ;; if region is active.
  (when (use-region-p)
    (while (and expreg--next-regions
                (let ((beg (cadr (car expreg--next-regions)))
                      (end (cddr (car expreg--next-regions))))
                  (and (<= (region-beginning) beg)
                       (<= end (region-end)))))
      ;; Pop from next-regions, push into prev-regions.
      (push (pop expreg--next-regions)
            expreg--prev-regions)))

  ;; Expand to the next expansion.
  (when expreg--next-regions
    (let ((region (pop expreg--next-regions)))
      (set-mark (cddr region))
      (goto-char (cadr region))
      (push region expreg--prev-regions)
      (unless transient-mark-mode
        (activate-mark))))

  (when expreg--verbose
    (message "blame: %s\nnext: %S\nprev: %S"
             (caar expreg--prev-regions)
             expreg--next-regions expreg--prev-regions)))

;;;###autoload
(defun expreg-contract ()
  "Contract region."
  (interactive)
  (when (and (use-region-p)
             (length> expreg--prev-regions 1))

    (push (pop expreg--prev-regions) expreg--next-regions)
    (set-mark (cddr (car expreg--prev-regions)))
    (goto-char (cadr (car expreg--prev-regions))))

  (when expreg--verbose
    (message "next: %S\nprev: %S"
             expreg--next-regions expreg--prev-regions)))

;;; Expansion functions

(defun expreg--subword ()
  "Return a list of regions of the CamelCase subword at point.
Only return something if ‘subword-mode’ is on, to keep consistency."
  (when subword-mode
    (let ((orig (point))
          beg end result)

      ;; Go forward then backward.
      (subword-forward)
      (setq end (point))
      (subword-backward)
      (setq beg (point))
      (skip-syntax-forward "w")
      ;; Make sure we stay in the word boundary. Because
      ;; ‘subword-backward/forward’ could go through parenthesis, etc.
      (when (>= (point) end)
        (push `(subword--forward . ,(cons beg end)) result))

      ;; Because ‘subword-backward/forward’ could go through
      ;; parenthesis, etc, we need to run it in reverse to handle the
      ;; case where point is at the end of a word.
      (goto-char orig)
      (subword-backward)
      (setq beg (point))
      (subword-forward)
      (setq end (point))
      (skip-syntax-backward "w")
      (when (<= (point) beg)
        (push `(subword--backward . ,(cons beg end)) result))

      result)))

(defun expreg--word ()
  "Return a list of regions within the word at point."
  ;; - subwords in camel-case (when ‘subword-mode’ is on).
  ;; - subwords by “-” or “_”.
  ;; - symbol-at-point
  ;; - within whitespace & paren/quote (but can contain punctuation)
  ;;   (“10–20”, “1.2”, “1,2”, etc). (This is technically not always
  ;;   within a word anymore...)
  (let ((orig (point))
        result
        beg end)

    ;; (2) subwords by “-” or “_”.
    (goto-char orig)
    (skip-syntax-forward "w")
    (setq end (point))
    (skip-syntax-backward "w")
    (setq beg (point))
    ;; Allow single char regions, see (ref:single-char-region).
    (push `(word--plain . ,(cons beg end)) result)

    ;; (3) symbol-at-point
    (goto-char orig)
    (skip-syntax-forward "w_")
    (setq end (point))
    (skip-syntax-backward "w_")
    (setq beg (point))
    ;; Avoid things like a single period.
    (when (> (- end beg) 1)
      (push `(word--symbol . ,(cons beg end)) result))

    ;; (4) within whitespace & paren. (Allow word constituents, symbol
    ;; constituents, punctuation, prefix (#' and ' in Elisp).)
    (goto-char orig)
    (skip-syntax-forward "w_.'")
    (setq end (point))
    (skip-syntax-backward "w_.'")
    (setq beg (point))
    ;; Avoid things like a single period.
    (when (> (- end beg) 1)
      (push `(word--within-space . ,(cons beg end)) result))

    ;; Return!
    result))

(defun expreg--treesit ()
  "Return a list of regions according to tree-sitter."
  (when (treesit-parser-list)
    (let ((parsers (append (treesit-parser-list)
                           (and (fboundp #'treesit-local-parsers-at)
                                (treesit-local-parsers-at (point)))))
          result)
      (dolist (parser parsers)
        (let ((node (treesit-node-at (point) parser))
              (root (treesit-parser-root-node parser))
              (lang (treesit-parser-language parser)))

          (while node
            (let ((beg (treesit-node-start node))
                  (end (treesit-node-end node)))
              (when (not (treesit-node-eq node root))
                (push (cons (intern (format "treesit--%s" lang))
                            (cons beg end))
                      result)))

            (setq node (treesit-node-parent node)))))
      result)))

(defun expreg--inside-list ()
  "Return a list of one region marking inside the list, or nil.
Does not move point."
  (condition-case nil
      (save-excursion
        ;; Inside a string? Move out of it first.
        (when (expreg--inside-string-p)
          (goto-char (expreg--start-of-comment-or-string)))

        (when (> (expreg--current-depth) 0)
          (let (beg end beg-w-spc end-w-spc)
            (goto-char (expreg--start-of-list))
            (save-excursion
              (forward-char)
              (setq beg-w-spc (point))
              (skip-syntax-forward "-")
              (setq beg (point)))

            (forward-list)
            (backward-char)
            (setq end-w-spc (point))
            (skip-syntax-backward "-")
            (setq end (point))

            `((inside-list . ,(cons beg end))
              (inside-list . ,(cons beg-w-spc end-w-spc))))))
    (scan-error nil)))

(defun expreg--list-at-point ()
  "Return a list of one region marking the list at point, or nil.
Point should be at the beginning or end of a list. Does not move
point."
  (unless (expreg--inside-string-p)
    (condition-case nil
        (save-excursion
          ;; Even if point is not at the beginning of a list, but
          ;; before a list (with only spaces between), we want to
          ;; return a region covering that list after point, for
          ;; convenience. But because this region will not cover
          ;; point, it will not pass the filtering, so this function
          ;; needs to be added to ‘expreg--validation-white-list’.
          (when (and (looking-at (rx (syntax whitespace)))
                     (not (eq 41 (char-syntax (or (char-before) ?x)))))
            (skip-syntax-forward "-"))

          ;; If at the end of a list and not the beginning of another
          ;; one, move to the beginning of the list. Corresponding
          ;; char for each int: 40=(, 39=', 41=).
          (when (and (eq 41 (char-syntax (or (char-before) ?x)))
                     (not (memq (char-syntax (or (char-after) ?x))
                                '(39 40))))
            (backward-list 1))

          (when (memq (char-syntax (or (char-after) ?x))
                      '(39 40))
            (let ((beg (if (eq 39 (char-syntax (or (char-before) ?x)))
                           (1- (point))
                         (point))))
              (forward-list)
              (list `(list-at-point . ,(cons beg (point)))))))
      (scan-error nil))))

(defun expreg--outside-list ()
  "Return a list of one region marking outside the list, or nil.
If find something, leave point at the beginning of the list."
  (let (beg end)
    (condition-case nil
        (when (> (expreg--current-depth) 0)
          (save-excursion

            ;; If point inside a list but not at the beginning of one,
            ;; move to the beginning of enclosing list.
            (when (> (expreg--current-depth) 0)
              (goto-char (expreg--start-of-list)))
            (setq beg (point))
            (forward-list)
            (setq end (point)))

          (when (and beg end)
            (goto-char beg)
            (list `(outside-list . ,(cons beg end)))))
      (scan-error nil))))

(defun expreg--string ()
  "Return regions marking the inside and outside of the string."
  (let ( outside-beg outside-end
         inside-beg inside-end)

    (condition-case nil
        (progn
          (if (expreg--inside-string-p)
              ;; Inside a string? Move to beginning.
              (goto-char (expreg--start-of-comment-or-string))

            ;; Not inside a string, but at the end of a string and not at
            ;; the beginning of another one? Move to beginning.
            (when (and (eq (char-syntax (or (char-before) ?x)) 34)
                       (not (eq (char-syntax (or (char-after) ?x)) 34)))
              (backward-sexp)))

          ;; Not inside a string and at the beginning of one.
          (when (and (not (expreg--inside-string-p))
                     (eq (char-syntax (or (char-after) ?x)) 34))

            (setq outside-beg (point))
            (forward-sexp)

            (when (eq (char-syntax (or (char-before) ?x)) 34)
              (setq outside-end (point))
              (backward-char)
              (setq inside-end (point))
              (goto-char outside-beg)
              (forward-char)
              (setq inside-beg (point))

              ;; It’s ok if point is at outside string and we return a
              ;; region marking inside the string: expreg will filter the
              ;; inside one out.
              (list `(string . ,(cons outside-beg outside-end))
                    `(string . ,(cons inside-beg inside-end))))))
      (scan-error nil))))

(defun expreg--list (&optional inhibit-recurse)
  "Return a list of regions determined by sexp level.

This routine returns the following regions:
1. The list before/after point
2. The inside of the innermost enclosing list
3. The outside of every layer of enclosing list

Note that the inside of outer layer lists are not captured.

If INHIBIT-RECURSE is non-nil, it doesn’t try to narrow to the
current string/comment and get lists inside."
  (condition-case nil
      (let (inside-results inside-string)
        (when (and (not inhibit-recurse)
                   (or (setq inside-string (expreg--inside-string-p))
                       (expreg--inside-comment-p)))
          ;; If point is inside a string, we narrow to the inside of
          ;; that string and compute again.
          (save-restriction
            (let ((orig (point))
                  (string-start (expreg--start-of-comment-or-string)))

              ;; Narrow to inside list.
              (goto-char string-start)
              ;; (forward-sexp)
              (if inside-string
                  ;; We could use ‘forward-sexp’, but narrowing plus
                  ;; ‘forward-sexp’ with a treesit backend would cause
                  ;; tree-sitter re-parse on the narrowed region and
                  ;; then re-parse on the widened region.
                  (goto-char (or (scan-sexps (point) 1)
                                 (buffer-end 1)))
                (forward-comment (buffer-size)))
              (if inside-string
                  (narrow-to-region (1+ string-start) (1- (point)))
                (narrow-to-region string-start (point)))
              (goto-char orig)
              (setq inside-results (expreg--list t)))))

        ;; Normal computation.
        (let ((inside-list (expreg--inside-list))
              (list-at-point (expreg--list-at-point))
              outside-list lst)

          ;; Compute outer-list.
          (while (setq lst (expreg--outside-list))
            (setq outside-list
                  (nconc lst outside-list)))

          (nconc inside-results inside-list list-at-point outside-list)))
    (scan-error nil)))

(defun expreg--comment ()
  "Return a list of regions containing comment."
  (let ((orig (point))
        (beg (point))
        (end (point))
        result forward-succeeded trailing-comment-p)

    ;; Go backward to the beginning of a comment (if exists).
    (while (expreg--inside-comment-p)
      (backward-char))

    ;; Now we are either at the beginning of a comment, or not on a
    ;; comment at all. (When there are multiple lines of comment,
    ;; each line is an individual comment.)
    (while (and (save-excursion
                  (expreg--inside-comment-p
                   (min (point-max) (1+ (point)))))
                (forward-comment 1))
      (setq end (point))
      (setq forward-succeeded t))
    (while (and (save-excursion
                  (expreg--inside-comment-p
                   (max (point-min) (1- (point)))))
                (forward-comment -1))
      (setq beg (point)))

    (goto-char beg)
    (setq trailing-comment-p
          (not (looking-back (rx bol (* whitespace))
                             (line-beginning-position))))
    (when (not trailing-comment-p)
      ;; Move BEG to BOL.
      (skip-chars-backward " \t")
      (setq beg (point))

      ;; Move END to BOL.
      (goto-char end)
      (skip-chars-backward " \t")
      (setq end (point)))

    (when (and forward-succeeded
               ;; If we are at the BOL of the line below a comment,
               ;; don’t include this comment. (END will be at the
               ;; BOL of the line after the comment.)
               (< orig end))
      (push `(comment . ,(cons beg end)) result))
    result))

(defun expreg--sentence ()
  "Return a list of regions containing surrounding sentences."
  (ignore-errors
    (let (beg end)
      (forward-sentence)
      (setq end (point))
      (backward-sentence)
      (setq beg (point))
      `((sentence . ,(cons beg end))))))

(defun expreg--paragraph-defun ()
  "Return a list of regions containing paragraphs or defuns."
  (condition-case nil
      (let ((orig (point))
            beg end result)

        (when beginning-of-defun-function
          (save-excursion
            (when (beginning-of-defun)
              (setq beg (point))
              (end-of-defun)
              (setq end (point))
              ;; If we are at the BOL right below a defun, don’t mark
              ;; that defun.
              (unless (eq orig end)
                (push `(paragraph-defun . ,(cons beg end)) result)))))

        (when (or (derived-mode-p 'text-mode)
                  (eq major-mode 'fundamental-mode))
          (save-excursion
            (backward-paragraph)
            (skip-syntax-forward "-")
            (setq beg (point))
            (forward-paragraph)
            (setq end (point))
            (push `(paragraph . ,(cons beg end)) result)))

        result)
    (scan-error nil)))


(provide 'expreg)

;;; expreg.el ends here
