;;; portal-org.el --- Org links and previews in Portal web views -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Two Org integrations.  A "portal:" link opens its URL in a Portal web view,
;; and `org-store-link' in a web buffer stores one for the page, or a file
;; link for a preview.  `portal-render-org' previews an Org file the way
;; `portal-render-markdown' previews Markdown: Emacs exports the file to HTML,
;; including edits not saved yet, and the app host shows it with the Markdown
;; preview's styles, its images loaded from disk.  Only Emacs can export Org,
;; so the page hands every link to a local file to Emacs: a link to another
;; Org file opens that file in the same preview, where l and r go back and
;; forward, and a link to any other file visits it in another pane.  Code
;; blocks never run for a preview.  portal.el loads this file with Org's
;; links.

(require 'cl-lib)
(require 'ol)
(require 'url-util)
(require 'portal-web)

(declare-function org-export-as "ox" (backend &optional subtreep visible-only body-only ext-plist))
(declare-function org-export-derived-backend-p "ox" (backend &rest backends))
(declare-function org-get-title "org" (&optional buffer-or-file))
(declare-function portal--inspect "portal-view" (target))
(declare-function org-roam-node-from-id "org-roam-node" (id))
(declare-function org-roam-node-file "org-roam-node" (node))
(declare-function xml-escape-string "xml" (string &optional noerror))
(defvar org-export-use-babel)
(defvar org-export-with-broken-links)
(defvar org-html-link-org-files-as-html)
(defvar org-html-htmlize-output-type)
(defvar org-html-prefer-user-labels)

(defgroup portal-org nil "Org links and previews in Portal web views." :group 'portal)

(defcustom portal-org-preview-directory
  (expand-file-name "portal-org/" temporary-file-directory)
  "Directory where `portal-render-org' keeps the HTML it exports.
Each previewed Org file has one file here, replaced by each export."
  :type 'directory)

;;; Links.

(defun portal-org-link-open (url &optional browser)
  "Open URL, a \"portal:\" link, in a Portal web view.
With a prefix argument, BROWSER, open it in the default browser instead."
  (if browser (browse-url-default-browser url) (portal-open-url url)))

(defun portal-org-link-store ()
  "Store a link to what this Portal web buffer shows, for `org-store-link'.
A page is a \"portal:\" link, and a Markdown or Org preview a link to its
file.  Other hosted apps store none."
  (when (and (derived-mode-p 'portal-web-mode) portal-web--target)
    (if-let* ((file (or portal-web--markdown portal-web--org)))
        (org-link-store-props :type "file" :link (concat "file:" (abbreviate-file-name file))
                              :description (file-name-nondirectory file))
      (unless portal-web--hosted-path
        (let* ((url (portal-web-current-url))
               (title (plist-get (portal--inspect portal-web--target) :title)))
          (org-link-store-props :type "portal" :link (concat "portal:" url)
                                :description (if (and title (not (string-empty-p title)))
                                                 title
                                               url)))))))

(defun portal-org-link-export (url description backend _info)
  "Export a \"portal:\" link to URL, with DESCRIPTION, for BACKEND: as the URL."
  (let ((description (or description url)))
    ;; Markdown derives from HTML, so it comes first.
    (cond ((org-export-derived-backend-p backend 'md) (format "[%s](%s)" description url))
          ((org-export-derived-backend-p backend 'html)
           (require 'xml)
           (format "<a href=\"%s\">%s</a>" (xml-escape-string url) (xml-escape-string description)))
          ((org-export-derived-backend-p backend 'latex)
           (format "\\href{%s}{%s}" (replace-regexp-in-string "[%#]" "\\\\\\&" url) description))
          ((equal description url) url)
          (t (format "%s (%s)" description url)))))

(org-link-set-parameters "portal"
                         :follow #'portal-org-link-open
                         :store #'portal-org-link-store
                         :export #'portal-org-link-export)

;;; Previews.

(defun portal-org--html-file (file)
  "Return the file in `portal-org-preview-directory' that previews Org FILE."
  (expand-file-name (concat (md5 file) ".html") portal-org-preview-directory))

(defun portal-org--path (file &optional fragment)
  "Return the app host path that previews Org FILE, at FRAGMENT if non-nil."
  (concat "/org?path=" (url-hexify-string (portal-org--html-file file))
          "&source=" (url-hexify-string file)
          (and fragment (concat "#" fragment))))

(defun portal-org--roam-file (id)
  "Return the file of the Org-roam node ID, or nil without Org-roam or the node."
  (when (fboundp 'org-roam-node-from-id)
    (ignore-errors
      (when-let* ((node (org-roam-node-from-id id)))
        (org-roam-node-file node)))))

(defun portal-org--find-id (find)
  "Return a replacement for FIND, `org-id-find' or `org-id-find-id-file'.
It looks an ID up in Org-roam's database first, where Org-roam is loaded,
and lets an ID that Org cannot find either be a broken link rather than
an error, as when `org-id-track-globally' is off."
  (let ((original (symbol-function find)))
    (lambda (id &rest arguments)
      (if-let* ((file (portal-org--roam-file id)))
          (if (eq find 'org-id-find-id-file) file (cons file nil))
        (ignore-errors (apply original id arguments))))))

(defun portal-org--export (file)
  "Export Org FILE to its preview's HTML file, and return that file.
A buffer visiting FILE exports its text, saved or not; otherwise FILE is
read from disk.  Code blocks do not run, broken links are marked rather
than stopping the export, and links to other Org files stay links to
them.  ID links, Org-roam's included, become links to their files."
  (require 'ox-html)
  (require 'org-id)
  (let* ((visiting (find-buffer-visiting file))
         (buffer (or visiting (generate-new-buffer " *portal-org-export*")))
         (output (portal-org--html-file file))
         (find (portal-org--find-id 'org-id-find))
         (find-file (portal-org--find-id 'org-id-find-id-file)))
    (unwind-protect
        (with-current-buffer buffer
          (unless visiting
            (insert-file-contents file)
            (setq default-directory (file-name-directory file))
            (delay-mode-hooks (org-mode)))
          (let* ((org-export-use-babel nil)
                 (org-export-with-broken-links 'mark)
                 (org-html-link-org-files-as-html nil)
                 ;; Headings with an ID get it as their anchor, which ID
                 ;; links from other files, as Org-roam's, point to.
                 (org-html-prefer-user-labels t)
                 ;; Without htmlize, code shows plain, without a warning.
                 (org-html-htmlize-output-type
                  (and (require 'htmlize nil t) org-html-htmlize-output-type))
                 (title (or (ignore-errors (org-get-title)) (file-name-base file)))
                 (body (cl-letf (((symbol-function 'org-id-find) find)
                                 ((symbol-function 'org-id-find-id-file) find-file))
                         (org-export-as 'html nil nil t '(:with-toc nil)))))
            (make-directory (file-name-directory output) t)
            (let ((coding-system-for-write 'utf-8))
              (with-temp-file output
                (insert "<h1 class=\"title\">" (url-insert-entities-in-string title) "</h1>\n"
                        body)))))
      (unless visiting (kill-buffer buffer)))
    output))

(defun portal-org--refresh ()
  "Export the Org file this preview shows again, before the view reloads it."
  (when portal-web--org (portal-org--export portal-web--org)))

(defun portal-org--follow (file fragment)
  "Show Org FILE, at FRAGMENT if non-nil, in this preview, and return t.
FILE is a local file the preview links to; return nil for any other kind
of file, which Emacs visits instead.  The view keeps the keyboard."
  (when (string-match-p "\\.org\\'" file)
    (unless (file-readable-p file)
      (user-error "Cannot preview %s: it is not readable" file))
    (portal-org--export file)
    (setq portal-web--hosted-path (portal-org--path file fragment)
          portal-web--org file)
    (portal-web--load-hosted)
    (when (equal (portal-view-target) portal-web--target)
      (portal-view-focus))
    t))

(defun portal-org--setup (file)
  "Make this web buffer an Org preview of FILE."
  (setq portal-web--org file
        portal-web--refresh-function #'portal-org--refresh
        portal-web--follow-function #'portal-org--follow))

;;;###autoload
(defun portal-render-org (file)
  "Preview Org FILE, as HTML exported by Emacs, in a web view.
Use the current buffer's file when it is in Org mode or has an .org
extension; otherwise prompt for FILE.  With a prefix argument, always
prompt.  A buffer visiting FILE exports its text, even unsaved edits;
code blocks never run.  Previewing the same file again reuses its buffer,
and g exports it again.  A link to another Org file opens it in the same
preview, and l and r go back and forward; a link to any other local file
opens it in another pane, as does `portal-render-open-in-emacs' for the
file on screen.  Images show from disk, and web links open in the default
browser."
  (interactive
   (list
    (if (and (not current-prefix-arg) buffer-file-name
             (or (derived-mode-p 'org-mode)
                 (string-match-p "\\.org\\'" buffer-file-name)))
        buffer-file-name
      (read-file-name "Preview Org file: " nil buffer-file-name t))))
  (let ((path (expand-file-name file)))
    (when (file-remote-p path)
      (user-error "Choose a local Org file"))
    (unless (and (file-regular-p path) (file-readable-p path))
      (user-error "Choose a readable regular file: %s" path))
    (let ((hosted (portal-org--path path)))
      ;; A preview showing it exports it again when it reloads.
      (unless (portal-web--find 'portal-web--hosted-path hosted)
        (portal-org--export path))
      (portal-web--visit-hosted hosted (file-name-nondirectory path) "markdown"))
    (portal-org--setup path)))

(provide 'portal-org)
;;; portal-org.el ends here
