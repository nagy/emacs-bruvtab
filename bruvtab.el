;;; bruvtab.el --- Show bruvtab URLs for EXWM Firefox windows -*- lexical-binding: t; -*-

;; Author: user
;; Package-Requires: ((emacs "28.1"))
;; Keywords: web, exwm

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Glue between EXWM X11 windows and the bruvtab/brotab `--json' commands.
;; bruvtab identifies browser windows as "<prefix>.<window_id>" (e.g. "a.1")
;; but does not expose the X11 window id.  EXWM gives us the X11 window id
;; and the window title, so the two sides are joined by title:
;;
;;   - Firefox sets _NET_WM_NAME to "<page title> - Mozilla Firefox".
;;     EXWM copies that into the buffer-local `exwm-title'.
;;   - bruvtab's `active --json' gives each window's active tab id, and
;;     `tabs --json' gives that tab's `title'.  Strip the Firefox suffix
;;     from the X11 title and match it against the active tab title.
;;
;; This is deterministic (no ambiguity when two windows open at once) and
;; works on demand, so no background process is required.  A background
;; tracker is also provided as a fallback for cases where titles do not
;; match (e.g. windows whose title is just "Mozilla Firefox").

;; Entry points to try:
;;
;;   (bruvtab-windows)            => ((WINDOW-ID . TAB-COUNT) ...)
;;   (bruvtab-tabs)               => list of tab alists
;;   (bruvtab-active)             => ((WINDOW-ID . TAB-ID) ...)
;;   (bruvtab-url-for-buffer (current-buffer))  => URL or nil
;;   M-x bruvtab-show-url
;;   M-x bruvtab-start-window-tracking   (optional fallback)
;;
;; URL example, evaluated in an `exwm-mode' buffer showing Firefox:
;;
;;   (bruvtab-url-for-buffer (current-buffer))
;;     => "https://www.youtube.com/watch?v=PTuGGdDuyPI"

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; EXWM internals (declared only to keep the byte-compiler quiet).
(defvar exwm--id)
(defvar exwm--id-buffer-alist)
(defvar exwm-class-name)
(defvar exwm-instance-name)
(defvar exwm-title)

(defgroup bruvtab nil
  "bruvtab (brotab) integration for EXWM Firefox windows."
  :group 'web)

(defcustom bruvtab-program "bruvtab"
  "Name or path of the bruvtab executable."
  :type 'string)

(defcustom bruvtab-json-flag "--json"
  "Command-line flag that makes bruvtab emit JSON."
  :type 'string)

(defcustom bruvtab-firefox-class-regexp
  "\\`\\(?:Navigator\\|firefox\\|Firefox\\|firefox-esr\\|firefox-developer-edition\\|nightly\\|aurora\\|iceweasel\\|librewolf\\|waterfox\\)\\'"
  "Regexp matching the WM_CLASS class or instance of a Firefox window.
Tested (case-insensitively, via `case-fold-search') against both
`exwm-class-name' and `exwm-instance-name'."
  :type 'regexp)

(defconst bruvtab--firefox-brand
  (concat "\\(?:Mozilla \\)?"
          "\\(?:Firefox\\(?:\\s-+\\(?:Nightly\\|Developer Edition\\|ESR"
          "\\|Beta\\|Alpha\\|Preview\\)\\)?"
          "\\|Nightly\\|Aurora\\|Waterfox\\|LibreWolf\\|Iceweasel\\)")
  "Regexp fragment matching a Firefox-family brand.")

(defconst bruvtab--firefox-private-suffix
  "\\(?:\\s-*(\\(?:Private\\(?: Browsing\\)?\\|Work\\|Personal\\))\\)?"
  "Regexp fragment matching an optional private-window parenthetical.")

(defcustom bruvtab-firefox-title-suffix-regexp
  (concat "\\s-*[-—–]\\s-*"
          bruvtab--firefox-brand
          bruvtab--firefox-private-suffix
          "\\s-*\\'")
  "Regexp matching the browser suffix Firefox appends to a window title.
The match must reach end of string.  Used only to strip the suffix from an
X11 window title before comparing it with a bruvtab tab title."
  :type 'regexp)

(defcustom bruvtab-firefox-bare-title-regexp
  (concat "\\`"
          bruvtab--firefox-brand
          bruvtab--firefox-private-suffix
          "\\s-*\\'")
  "Regexp matching a Firefox window title that has no page title.
Such titles (e.g. \"Mozilla Firefox\") normalize to the empty string."
  :type 'regexp)

;;; Process + JSON -----------------------------------------------------------

(defun bruvtab--call (&rest args)
  "Run `bruvtab-program' with ARGS and return stdout as a trimmed string.
Signals an error on non-zero exit."
  (with-temp-buffer
    (let ((status (apply #'call-process bruvtab-program nil (list t t) nil args)))
      (unless (eql status 0)
        (error "bruvtab %s failed (exit %s): %s"
               (mapconcat #'shell-quote-argument args " ")
               status
               (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun bruvtab--json (&rest args)
  "Run bruvtab with ARGS plus `bruvtab-json-flag' and parse JSON output.
Returns a list or alist (symbol keys); JSON false/null become nil."
  (let ((out (apply #'bruvtab--call (append args (list bruvtab-json-flag)))))
    (if (string-empty-p out)
        nil
      (json-parse-string out
                         :object-type 'alist
                         :array-type 'list
                         :null-object nil
                         :false-object nil))))

;;; bruvtab queries ----------------------------------------------------------

(defun bruvtab-windows ()
  "Return bruvtab windows as an alist of (WINDOW-ID . TAB-COUNT)."
  (mapcar (lambda (w)
            (cons (cdr (assq 'window w))
                  (cdr (assq 'tabs w))))
          (bruvtab--json "windows")))

(defun bruvtab-tabs ()
  "Return bruvtab tabs as a list of alists.
Each alist has keys `id', `title', `url', `playing' and `muted'."
  (bruvtab--json "tabs"))

(defun bruvtab-active ()
  "Return bruvtab active tabs as an alist of (WINDOW-ID . TAB-ID)."
  (mapcar (lambda (a)
            (let ((tab-id (cdr (assq 'id a))))
              (cons (bruvtab--window-id-of tab-id) tab-id)))
          (bruvtab--json "active")))

(defun bruvtab--window-id-of (id)
  "Return the window-id part of bruvtab ID (\"a.1\" from \"a.1.2\").
Only strip the final \".N\" segment when a dot remains, so a plain window
id such as \"a.1\" is returned unchanged."
  (if (and id
           (string-match "\\`\\(.*\\)\\.[^.]+\\'" id)
           (string-match-p "\\." (match-string 1 id)))
      (match-string 1 id)
    id))

(defun bruvtab--tabs-by-id ()
  "Return a hash table mapping tab id to tab alist."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (tab (bruvtab-tabs) h)
      (puthash (cdr (assq 'id tab)) tab h))))

(defun bruvtab-active-tab-for-window (window-id)
  "Return the active tab alist for WINDOW-ID (e.g. \"a.1\"), or nil."
  (when-let* ((active (assoc window-id (bruvtab-active))))
    (let ((tab-id (cdr active)))
      (cl-find tab-id (bruvtab-tabs)
               :key (lambda (tab) (cdr (assq 'id tab)))
               :test #'equal))))

(defun bruvtab-url-for-window (window-id)
  "Return the URL of the active tab in WINDOW-ID, or nil."
  (when-let* ((tab (bruvtab-active-tab-for-window window-id)))
    (cdr (assq 'url tab))))

;;; Title normalization ------------------------------------------------------

(defun bruvtab--normalize-title (title)
  "Strip the Firefox window-title suffix from TITLE and trim it.
Returns the page-title portion used for matching bruvtab tab titles."
  (when (stringp title)
    (let ((trimmed (string-trim title)))
      (cond
       ((string-match bruvtab-firefox-bare-title-regexp trimmed) "")
       ((string-match bruvtab-firefox-title-suffix-regexp trimmed)
        (string-trim (substring trimmed 0 (match-beginning 0))))
       (t trimmed)))))

;;; X11 / EXWM side ----------------------------------------------------------

(defun bruvtab--x11-id (buffer)
  "Return the X11 window id of EXWM BUFFER, or nil."
  (with-current-buffer buffer
    (bound-and-true-p exwm--id)))

(defun bruvtab-firefox-buffer-p (buffer)
  "Return non-nil if BUFFER is an EXWM-managed Firefox window."
  (with-current-buffer buffer
    (and (bound-and-true-p exwm--id)
         (or (and (stringp exwm-class-name)
                  (string-match-p bruvtab-firefox-class-regexp exwm-class-name))
             (and (stringp exwm-instance-name)
                  (string-match-p bruvtab-firefox-class-regexp exwm-instance-name)))
         t)))

(defun bruvtab--buffer-title (buffer)
  "Return the normalized `exwm-title' of EXWM BUFFER, or nil."
  (with-current-buffer buffer
    (when (stringp exwm-title)
      (bruvtab--normalize-title exwm-title))))

(defun bruvtab--firefox-x11-windows ()
  "Return an alist of (X11-ID . BUFFER) for managed Firefox windows."
  (let (result)
    (dolist (pair exwm--id-buffer-alist)
      (let ((id (car pair))
            (buffer (cdr pair)))
        (when (and (buffer-live-p buffer)
                   (bruvtab-firefox-buffer-p buffer))
          (push (cons id buffer) result))))
    result))

;;; X11 <-> bruvtab window-id mapping ----------------------------------------

(defun bruvtab--active-window-title->id ()
  "Return a hash table mapping normalized active-tab title -> window id."
  (let* ((tabs (bruvtab--tabs-by-id))
         (result (make-hash-table :test 'equal)))
    (dolist (active (bruvtab-active) result)
      (let* ((window-id (car active))
             (tab (gethash (cdr active) tabs)))
        (when tab
          (let ((title (bruvtab--normalize-title (cdr (assq 'title tab)))))
            (when (and (stringp title)
                       (not (gethash title result)))
              (puthash title window-id result))))))))

(defun bruvtab--window-id-by-title (buffer &optional title->id)
  "Return the bruvtab window id for BUFFER by matching its title."
  (when-let* ((title (bruvtab--buffer-title buffer)))
    (gethash title (or title->id (bruvtab--active-window-title->id)))))

;; Background window-id map (fallback when titles do not match).

(defvar bruvtab-window-id-map (make-hash-table)
  "Hash table mapping X11 window id (integer) -> bruvtab window id (string).
Maintained by `bruvtab-update-window-id-map' / `bruvtab-start-window-tracking'.")

(defcustom bruvtab-track-interval 5.0
  "Seconds between updates of `bruvtab-window-id-map' while tracking."
  :type 'number)

(defvar bruvtab--track-timer nil)

(defun bruvtab-update-window-id-map ()
  "Recompute `bruvtab-window-id-map' from current X11 and bruvtab state.

Keeps existing mappings that are still valid; matches new Firefox windows
to bruvtab window ids by active-tab title; and, when exactly one X11 window
and one bruvtab window remain unassigned, pairs them.  Ambiguous cases are
left unassigned."
  (let* ((x11-windows (bruvtab--firefox-x11-windows))
         (x11-ids (mapcar #'car x11-windows))
         (bw-ids (mapcar #'car (bruvtab-windows)))
         (title->id (bruvtab--active-window-title->id))
         (new-map (make-hash-table)))
    (cl-labels ((x11-taken-p (x) (gethash x new-map))
                (bw-taken-p (b) (member b (hash-table-values new-map)))
                (assign (x b) (puthash x b new-map)))
      ;; Retain valid existing mappings.
      (maphash (lambda (x b)
                 (when (and (memql x x11-ids) (member b bw-ids))
                   (assign x b)))
               bruvtab-window-id-map)
      ;; Title-match unmapped X11 windows.
      (dolist (pair x11-windows)
        (let ((x (car pair)))
          (unless (x11-taken-p x)
            (when-let* ((title (bruvtab--buffer-title (cdr pair)))
                        (b (gethash title title->id)))
              (unless (bw-taken-p b)
                (assign x b))))))
      ;; Single-unassigned heuristic.
      (let ((free-x (cl-remove-if #'x11-taken-p x11-ids))
            (free-b (cl-remove-if #'bw-taken-p bw-ids)))
        (when (and (= (length free-x) 1) (= (length free-b) 1))
          (assign (car free-x) (car free-b)))))
    (setq bruvtab-window-id-map new-map)))

(defun bruvtab-window-id-alist ()
  "Return `bruvtab-window-id-map' as an alist of (X11-ID . WINDOW-ID)."
  (let (result)
    (maphash (lambda (x b) (push (cons x b) result)) bruvtab-window-id-map)
    (sort result (lambda (a b) (< (car a) (car b))))))

(defun bruvtab-start-window-tracking ()
  "Start periodically refreshing `bruvtab-window-id-map'."
  (interactive)
  (bruvtab-update-window-id-map)
  (unless bruvtab--track-timer
    (setq bruvtab--track-timer
          (run-with-timer bruvtab-track-interval bruvtab-track-interval
                          #'bruvtab-update-window-id-map))))

(defun bruvtab-stop-window-tracking ()
  "Stop refreshing `bruvtab-window-id-map'."
  (interactive)
  (when bruvtab--track-timer
    (cancel-timer bruvtab--track-timer)
    (setq bruvtab--track-timer nil)))

;;; Buffer-oriented entry points ---------------------------------------------

(defun bruvtab-window-id-for-buffer (buffer)
  "Return the bruvtab window id (e.g. \"a.1\") for EXWM BUFFER, or nil."
  (when (bruvtab-firefox-buffer-p buffer)
    (let ((x11-id (bruvtab--x11-id buffer)))
      (or (bruvtab--window-id-by-title buffer)
          (and x11-id (gethash x11-id bruvtab-window-id-map))))))

(defun bruvtab-tab-for-buffer (buffer)
  "Return the active tab alist for EXWM BUFFER, or nil."
  (when-let* ((window-id (bruvtab-window-id-for-buffer buffer)))
    (bruvtab-active-tab-for-window window-id)))

(defun bruvtab-url-for-buffer (buffer)
  "Return the URL currently displayed in EXWM BUFFER, or nil.
BUFFER should be an `exwm-mode' buffer showing a Firefox window."
  (when-let* ((tab (bruvtab-tab-for-buffer buffer)))
    (cdr (assq 'url tab))))

;;; Commands -----------------------------------------------------------------

(defun bruvtab-show-url ()
  "Display the bruvtab URL of the current EXWM Firefox window."
  (interactive)
  (cond
   ((not (bruvtab-firefox-buffer-p (current-buffer)))
    (user-error "Not a Firefox EXWM window"))
   ((null (bruvtab-tab-for-buffer (current-buffer)))
    (message "No bruvtab match for %s" (buffer-name)))
   (t
    (message "%s" (bruvtab-url-for-buffer (current-buffer))))))

(defun bruvtab-debug ()
  "Show a debug table of EXWM Firefox windows and their bruvtab URLs."
  (interactive)
  (with-current-buffer (get-buffer-create "*bruvtab debug*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "%-9s %-10s %-40s %s\n" "X11-ID" "WINDOW" "TITLE" "URL"))
      (dolist (pair (bruvtab--firefox-x11-windows))
        (let* ((buffer (cdr pair))
               (window-id (ignore-errors (bruvtab-window-id-for-buffer buffer)))
               (url (and window-id (ignore-errors (bruvtab-url-for-buffer buffer)))))
          (insert (format "%-9s %-10s %-40s %s\n"
                          (car pair)
                          (or window-id "-")
                          (or (bruvtab--buffer-title buffer) "-")
                          (or url "-"))))))
    (display-buffer (current-buffer))))

(provide 'bruvtab)
;;; bruvtab.el ends here
