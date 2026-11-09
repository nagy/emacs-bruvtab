;;; bruvtab-tests.el --- ERT tests for bruvtab -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is part of bruvtab.

;; bruvtab is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; bruvtab is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with bruvtab.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tests for the parts of bruvtab that do not need a running mediator or
;; an X11 display.  The native HTTP transport, the tab list and the X11
;; window list are mocked, so the suite runs in a sandbox with no
;; network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'bruvtab)

;;;; Helpers

(defun bruvtab-test--tab (id title url)
  "Return a bruvtab tab alist with ID, TITLE and URL."
  (declare (pure t) (side-effect-free t))
  (list (cons 'id id) (cons 'title title) (cons 'url url)
        (cons 'playing nil) (cons 'muted nil)))

(defun bruvtab-test--snapshot (tabs active)
  "Return a snapshot plist built from TABS and ACTIVE."
  (let* ((by-id (bruvtab--tabs-by-id tabs))
         (title->id (bruvtab--active-window-title->id active by-id)))
    (list :tabs tabs :active active
          :tabs-by-id by-id :title->id title->id)))

(defmacro bruvtab-test--with-firefox-buffer (title &rest body)
  "Run BODY in a temporary buffer that looks like a Firefox EXWM window.
TITLE becomes the buffer's `exwm-title'.  The buffer has a live
`exwm--id', so `bruvtab-firefox-buffer-p' accepts it."
  (declare (indent 1) (debug t))
  `(let ((buf (generate-new-buffer " *bruvtab-test*")))
     (unwind-protect
         (progn
           (with-current-buffer buf
             (setq-local exwm--id 1)
             (setq-local exwm-class-name "Navigator")
             (setq-local exwm-instance-name "Navigator")
             (setq-local exwm-title ,title))
           (with-current-buffer buf ,@body))
       (kill-buffer buf))))

;;;; Title normalization

(ert-deftest bruvtab-test-normalize-title-typed-suffix ()
  "Firefox suffixes with an em dash, en dash or hyphen are stripped."
  (should (equal (bruvtab--normalize-title "Page — Mozilla Firefox") "Page"))
  (should (equal (bruvtab--normalize-title "Page – Firefox") "Page"))
  (should (equal (bruvtab--normalize-title "Page - Firefox") "Page"))
  (should (equal (bruvtab--normalize-title "Page — LibreWolf") "Page"))
  (should (equal (bruvtab--normalize-title
                  "Page — Mozilla Firefox (Private Browsing)")
                 "Page")))

(ert-deftest bruvtab-test-normalize-title-bare ()
  "A window title without a page title normalizes to the empty string."
  (should (equal (bruvtab--normalize-title "Mozilla Firefox") ""))
  (should (equal (bruvtab--normalize-title "Firefox") ""))
  (should (equal (bruvtab--normalize-title "Mozilla Firefox (Private Browsing)")
                 "")))

(ert-deftest bruvtab-test-normalize-title-plain ()
  "A title with no browser suffix comes back trimmed and unchanged."
  (should (equal (bruvtab--normalize-title "  Plain title  ") "Plain title"))
  (should (equal (bruvtab--normalize-title "Dash - inside") "Dash - inside"))
  (should (null (bruvtab--normalize-title nil))))

;;;; Window id splitting

(ert-deftest bruvtab-test-window-id-of ()
  "Only the final tab segment is stripped, and only when a dot remains."
  (should (equal (bruvtab--window-id-of "a.1.2") "a.1"))
  (should (equal (bruvtab--window-id-of "a.259.42") "a.259"))
  (should (equal (bruvtab--window-id-of "a.1") "a.1"))
  (should (equal (bruvtab--window-id-of "1.2") "1.2"))
  (should (equal (bruvtab--window-id-of "a.b.c") "a.b"))
  (should (null (bruvtab--window-id-of nil))))

(ert-deftest bruvtab-test-window-id-of-edges ()
  "Paths that do not look like a tab id come back unchanged."
  (dolist (case '(("a.1." . "a.1.")
                  (".2" . ".2")
                  ("a" . "a")
                  ("a..b" . "a.")
                  ("a.1.2.3" . "a.1.2")))
    (should (equal (bruvtab--window-id-of (car case)) (cdr case)))))

(ert-deftest bruvtab-test-window-id-of-keeps-match-data ()
  "The split leaves the global match data untouched."
  (string-match (rx (group "b")) "ab")
  (let ((before (match-data)))
    (bruvtab--window-id-of "a.1.2")
    (should (equal (match-data) before))))

(ert-deftest bruvtab-test-window-ids-from-tabs-order ()
  "Window ids keep the tab order and drop duplicates."
  (should (equal (bruvtab--window-ids-from-tabs
                  (list (bruvtab-test--tab "a.1.1" "One" "u")
                        (bruvtab-test--tab "a.2.1" "Two" "u")
                        (bruvtab-test--tab "a.1.2" "Three" "u")))
                 '("a.1" "a.2"))))

;;;; Native backend parsing

(ert-deftest bruvtab-test-native-parse ()
  "The native backend splits tab lines and comma-separated active ids."
  (cl-letf (((symbol-function 'bruvtab--native-clients)
             (lambda () '(("a." "127.0.0.1" 4625))))
            ((symbol-function 'bruvtab--native-fetch)
             (lambda (_host _port path)
               (if (equal path "/list_tabs")
                   "1.2\tFirst\tfirst\n1.3\tSecond\tsecond\n"
                 "1.2,1.3"))))
    (let* ((result (bruvtab--native-fetch-all t t))
           (tabs (car result))
           (active (cadr result)))
      (should (equal (mapcar (lambda (tab) (cdr (assq 'id tab))) tabs)
                     '("a.1.2" "a.1.3")))
      (should (equal (cdr (assq 'title (car tabs))) "First"))
      (should (equal (cdr (assq 'url (cadr tabs))) "second"))
      (should (equal active '(("a.1" . "a.1.2") ("a.1" . "a.1.3")))))))

(ert-deftest bruvtab-test-native-parse-skips-short-lines ()
  "A tab line without a URL is ignored instead of erroring."
  (cl-letf (((symbol-function 'bruvtab--native-clients)
             (lambda () '(("a." "127.0.0.1" 4625))))
            ((symbol-function 'bruvtab--native-fetch)
             (lambda (_host _port _path) "1.2\tOnly title\n")))
    (should (equal (bruvtab--native-fetch-all t nil) '(nil nil)))))

(ert-deftest bruvtab-test-native-tabs-skip-playing ()
  "The native tab list leaves `playing' and `muted' nil."
  (cl-letf (((symbol-function 'bruvtab--native-fetch-all)
             (lambda (&rest _)
               (list (list (bruvtab-test--tab "a.1.2" "T" "U")) nil))))
    (let ((tab (car (bruvtab-tabs))))
      (should (null (cdr (assq 'playing tab))))
      (should (null (cdr (assq 'muted tab)))))))

;;;; Snapshot lookups

(ert-deftest bruvtab-test-windows-counts ()
  "Windows are derived from the tab list, counting tabs per window."
  (cl-letf (((symbol-function 'bruvtab-tabs)
             (lambda ()
               (list (bruvtab-test--tab "a.1.1" "One" "u1")
                     (bruvtab-test--tab "a.1.2" "Two" "u2")
                     (bruvtab-test--tab "a.259.1" "Three" "u3")))))
    (should (equal (bruvtab-windows) '(("a.1" . 2) ("a.259" . 1))))))

(ert-deftest bruvtab-test-tabs-by-id ()
  "Tabs are indexed by their full id."
  (let ((by-id (bruvtab--tabs-by-id
                (list (bruvtab-test--tab "a.1.2" "T" "U")))))
    (should (equal (cdr (assq 'url (gethash "a.1.2" by-id))) "U"))
    (should (null (gethash "a.1" by-id)))))

(ert-deftest bruvtab-test-active-tab-for-window ()
  "The active tab alist comes from the snapshot's active list."
  (let ((snapshot (bruvtab-test--snapshot
                   (list (bruvtab-test--tab "a.1.2" "T" "U"))
                   '(("a.1" . "a.1.2")))))
    (should (equal (cdr (assq 'url (bruvtab-active-tab-for-window "a.1" snapshot)))
                   "U"))
    (should (null (bruvtab-active-tab-for-window "a.2" snapshot)))
    (should (null (bruvtab-url-for-window "a.2" snapshot)))))

(ert-deftest bruvtab-test-active-tab-for-window-missing-tab ()
  "An active id with no matching tab yields nil instead of erroring."
  (let ((snapshot (bruvtab-test--snapshot nil '(("a.1" . "a.1.2")))))
    (should (null (bruvtab-active-tab-for-window "a.1" snapshot)))))

;;;; Firefox detection

(ert-deftest bruvtab-test-firefox-buffer-p ()
  "WM_CLASS or WM_INSTANCE of a Firefox flavour identifies the window."
  (bruvtab-test--with-firefox-buffer "Page — Mozilla Firefox"
    (should (bruvtab-firefox-buffer-p (current-buffer))))
  (dolist (name '("Navigator" "firefox" "Firefox" "firefox-esr"
                  "firefox-developer-edition" "nightly" "aurora"
                  "iceweasel" "librewolf" "waterfox"))
    (bruvtab-test--with-firefox-buffer "T"
      (setq-local exwm-class-name name)
      (should (bruvtab-firefox-buffer-p (current-buffer))))))

(ert-deftest bruvtab-test-firefox-buffer-p-case-fold ()
  "Detection stays case-insensitive when `case-fold-search' is nil.
The class regexp spells some brands in one case only, so the predicate
must bind the flag instead of inheriting the buffer's value."
  (dolist (name '("LIBREWOLF" "FireFox" "LiBrEwOlF"))
    (bruvtab-test--with-firefox-buffer "T"
      (setq-local exwm-class-name name)
      (setq-local exwm-instance-name name)
      (setq-local case-fold-search nil)
      (should (bruvtab-firefox-buffer-p (current-buffer))))))

(ert-deftest bruvtab-test-firefox-buffer-p-other ()
  "A non-Firefox class and a buffer without an X11 id are rejected."
  (bruvtab-test--with-firefox-buffer "T"
    (setq-local exwm-class-name "Emacs")
    (setq-local exwm-instance-name "emacs")
    (should-not (bruvtab-firefox-buffer-p (current-buffer))))
  (let ((buf (generate-new-buffer " *bruvtab-test-plain*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local exwm-class-name "Navigator")
            (setq-local exwm-instance-name "Navigator"))
          (should-not (bruvtab-firefox-buffer-p buf)))
      (kill-buffer buf))))

;;;; Buffer to window id

(ert-deftest bruvtab-test-window-id-by-title ()
  "The title match is authoritative for the window id."
  (let ((snapshot (bruvtab-test--snapshot
                   (list (bruvtab-test--tab "a.2.1" "Page" "U"))
                   '(("a.2" . "a.2.1")))))
    (bruvtab-test--with-firefox-buffer "Page — Mozilla Firefox"
      (should (equal (bruvtab-window-id-for-buffer (current-buffer) snapshot)
                     "a.2")))))

(ert-deftest bruvtab-test-window-id-falls-back-to-map ()
  "A bare window title uses the tracked X11 id map."
  (let ((snapshot (bruvtab-test--snapshot
                   (list (bruvtab-test--tab "a.3.1" "Other" "U"))
                   '(("a.3" . "a.3.1"))))
        (bruvtab-window-id-map (make-hash-table)))
    (puthash 1 "a.3" bruvtab-window-id-map)
    (bruvtab-test--with-firefox-buffer "Mozilla Firefox"
      (should (equal (bruvtab-window-id-for-buffer (current-buffer) snapshot)
                     "a.3")))))

(ert-deftest bruvtab-test-url-for-buffer ()
  "The buffer entry point returns the active tab URL."
  (let ((snapshot (bruvtab-test--snapshot
                   (list (bruvtab-test--tab "a.2.1" "Page" "https://example.com"))
                   '(("a.2" . "a.2.1")))))
    (cl-letf (((symbol-function 'bruvtab--snapshot) (lambda () snapshot)))
      (bruvtab-test--with-firefox-buffer "Page — Mozilla Firefox"
        (should (equal (bruvtab-url-for-buffer (current-buffer))
                       "https://example.com"))))))

(ert-deftest bruvtab-test-url-for-buffer-accepts-snapshot ()
  "A supplied snapshot is used instead of fetching a new one."
  (let ((snapshot (bruvtab-test--snapshot
                   (list (bruvtab-test--tab "a.2.1" "Page" "https://example.com"))
                   '(("a.2" . "a.2.1"))))
        (fetches 0))
    (cl-letf (((symbol-function 'bruvtab--snapshot)
               (lambda () (cl-incf fetches) snapshot)))
      (bruvtab-test--with-firefox-buffer "Page — Mozilla Firefox"
        (should (equal (bruvtab-url-for-buffer (current-buffer) snapshot)
                       "https://example.com"))
        (should (= fetches 0))))))

(ert-deftest bruvtab-test-show-url-fetches-once ()
  "The command builds one snapshot and reuses it on both paths."
  (let ((snapshot (bruvtab-test--snapshot
                   (list (bruvtab-test--tab "a.2.1" "Page" "https://example.com"))
                   '(("a.2" . "a.2.1"))))
        (fetches 0)
        (messages nil))
    (cl-letf (((symbol-function 'bruvtab--snapshot)
               (lambda () (cl-incf fetches) snapshot))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (bruvtab-test--with-firefox-buffer "Page — Mozilla Firefox"
        (bruvtab-show-url)
        (should (= fetches 1))
        (should (equal (car messages) "https://example.com"))))
    (setq fetches 0)
    (cl-letf (((symbol-function 'bruvtab--snapshot)
               (lambda () (cl-incf fetches) snapshot)))
      (bruvtab-test--with-firefox-buffer "Some unmatched title — Mozilla Firefox"
        (bruvtab-show-url)
        (should (= fetches 1))))))

(ert-deftest bruvtab-test-show-url-non-firefox-no-probe ()
  "A non-Firefox buffer errors before the mediator is probed."
  (let ((fetches 0))
    (cl-letf (((symbol-function 'bruvtab--snapshot)
               (lambda () (cl-incf fetches) nil)))
      (with-temp-buffer
        (setq-local exwm-class-name "Emacs")
        (should-error (bruvtab-show-url) :type 'user-error))
      (should (= fetches 0)))))

(ert-deftest bruvtab-test-url-for-buffer-non-firefox ()
  "A non-Firefox buffer has no window id and no URL."
  (let ((snapshot (bruvtab-test--snapshot nil nil)))
    (cl-letf (((symbol-function 'bruvtab--snapshot) (lambda () snapshot)))
      (let ((buf (generate-new-buffer " *bruvtab-test-plain*")))
        (unwind-protect
            (progn
              (with-current-buffer buf (setq-local exwm-class-name "Emacs"))
              (should (null (bruvtab-window-id-for-buffer buf snapshot)))
              (should (null (bruvtab-url-for-buffer buf))))
          (kill-buffer buf))))))

;;;; Fallback tracker

(ert-deftest bruvtab-test-update-window-id-map-retains ()
  "An existing mapping survives while both sides still exist."
  (let ((bruvtab-window-id-map (make-hash-table)))
    (puthash 7 "a.1" bruvtab-window-id-map)
    (bruvtab-test--with-firefox-buffer "Page — Mozilla Firefox"
      (cl-letf (((symbol-function 'bruvtab--firefox-x11-windows)
                 (lambda () (list (cons 7 (current-buffer)))))
                ((symbol-function 'bruvtab--snapshot)
                 (lambda ()
                   (bruvtab-test--snapshot
                    (list (bruvtab-test--tab "a.1.1" "Page" "U"))
                    '(("a.1" . "a.1.1"))))))
        (bruvtab-update-window-id-map)
        (should (equal (gethash 7 bruvtab-window-id-map) "a.1"))))))

(ert-deftest bruvtab-test-update-window-id-map-drops-stale ()
  "A mapping whose bruvtab window disappeared is dropped."
  (let ((bruvtab-window-id-map (make-hash-table)))
    (puthash 7 "a.99" bruvtab-window-id-map)
    (bruvtab-test--with-firefox-buffer "Page — Mozilla Firefox"
      (cl-letf (((symbol-function 'bruvtab--firefox-x11-windows)
                 (lambda () (list (cons 7 (current-buffer)))))
                ((symbol-function 'bruvtab--snapshot)
                 (lambda ()
                   (bruvtab-test--snapshot
                    (list (bruvtab-test--tab "a.1.1" "Page" "U"))
                    '(("a.1" . "a.1.1"))))))
        (bruvtab-update-window-id-map)
        (should (equal (gethash 7 bruvtab-window-id-map) "a.1"))))))

(ert-deftest bruvtab-test-update-window-id-map-title-match ()
  "An unmapped X11 window is matched by its active tab title."
  (let ((bruvtab-window-id-map (make-hash-table)))
    (bruvtab-test--with-firefox-buffer "Page — Mozilla Firefox"
      (cl-letf (((symbol-function 'bruvtab--firefox-x11-windows)
                 (lambda () (list (cons 9 (current-buffer)))))
                ((symbol-function 'bruvtab--snapshot)
                 (lambda ()
                   (bruvtab-test--snapshot
                    (list (bruvtab-test--tab "a.2.1" "Page" "U"))
                    '(("a.2" . "a.2.1"))))))
        (bruvtab-update-window-id-map)
        (should (equal (gethash 9 bruvtab-window-id-map) "a.2"))))))

(ert-deftest bruvtab-test-update-window-id-map-single-unassigned ()
  "One unmatched X11 window pairs with one unmatched bruvtab window."
  (let ((bruvtab-window-id-map (make-hash-table)))
    (bruvtab-test--with-firefox-buffer "Mozilla Firefox"
      (cl-letf (((symbol-function 'bruvtab--firefox-x11-windows)
                 (lambda () (list (cons 11 (current-buffer)))))
                ((symbol-function 'bruvtab--snapshot)
                 (lambda ()
                   (bruvtab-test--snapshot
                    (list (bruvtab-test--tab "a.3.1" "Something else" "U"))
                    '(("a.3" . "a.3.1"))))))
        (bruvtab-update-window-id-map)
        (should (equal (gethash 11 bruvtab-window-id-map) "a.3"))))))

(ert-deftest bruvtab-test-update-window-id-map-ambiguous ()
  "Two unmatched X11 windows are left unassigned."
  (let ((bruvtab-window-id-map (make-hash-table))
        (first (generate-new-buffer " *bruvtab-test-a*"))
        (second (generate-new-buffer " *bruvtab-test-b*")))
    (unwind-protect
        (progn
          (dolist (buf (list first second))
            (with-current-buffer buf
              (setq-local exwm--id 1)
              (setq-local exwm-class-name "Navigator")
              (setq-local exwm-instance-name "Navigator")
              (setq-local exwm-title "Mozilla Firefox")))
          (cl-letf (((symbol-function 'bruvtab--firefox-x11-windows)
                     (lambda ()
                       (list (cons 21 first) (cons 22 second))))
                    ((symbol-function 'bruvtab--snapshot)
                     (lambda ()
                       (bruvtab-test--snapshot
                        (list (bruvtab-test--tab "a.4.1" "One" "U"))
                        '(("a.4" . "a.4.1"))))))
            (bruvtab-update-window-id-map)
            (should-not (gethash 21 bruvtab-window-id-map))
            (should-not (gethash 22 bruvtab-window-id-map))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest bruvtab-test-window-id-alist-sorted ()
  "The alist view is sorted by X11 id."
  (let ((bruvtab-window-id-map (make-hash-table)))
    (puthash 5 "a.2" bruvtab-window-id-map)
    (puthash 2 "a.1" bruvtab-window-id-map)
    (should (equal (bruvtab-window-id-alist)
                   '((2 . "a.1") (5 . "a.2"))))))

;;;; CLI backend and JSON

(ert-deftest bruvtab-test-cli-backend-active ()
  "The CLI backend turns the JSON active list into window/tab pairs."
  (let ((bruvtab-backend 'cli))
    (cl-letf (((symbol-function 'bruvtab--call)
               (lambda (&rest _)
                 "[{\"id\":\"a.1.2\",\"client\":\"a.\\tlocalhost:4625\\t1\\tfirefox\"}]")))
      (should (equal (bruvtab-active) '(("a.1" . "a.1.2")))))))

(ert-deftest bruvtab-test-json-false-is-nil ()
  "JSON false becomes nil, not the symbol `:false'."
  (cl-letf (((symbol-function 'bruvtab--call)
             (lambda (&rest _)
               "[{\"id\":\"a.1.2\",\"playing\":false,\"muted\":null}]")))
    (let ((tab (car (bruvtab--json "tabs"))))
      (should (null (cdr (assq 'playing tab))))
      (should (null (cdr (assq 'muted tab)))))))

(ert-deftest bruvtab-test-json-empty-is-nil ()
  "Empty CLI output parses to nil."
  (cl-letf (((symbol-function 'bruvtab--call) (lambda (&rest _) "")))
    (should (null (bruvtab--json "tabs")))))

(provide 'bruvtab-tests)
;;; bruvtab-tests.el ends here
