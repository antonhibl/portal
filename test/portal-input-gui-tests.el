;;; portal-input-gui-tests.el --- Real WebKit input ownership -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'portal-excalidraw-gui-tests)
(require 'portal-integration-tests)

(defmacro portal-input-gui--page (&rest body)
  (declare (indent 0))
  `(save-window-excursion
     (unwind-protect
         (progn
           (delete-other-windows)
           (select-frame-set-input-focus (selected-frame))
           (portal-open-url "data:text/html,<title>Input ready</title><input autofocus><script>window.keys=[];window.ups=0;document.addEventListener('keydown',e=>keys.push([e.key,e.ctrlKey,e.isTrusted]));document.addEventListener('keyup',e=>window.ups=(window.ups||0)+1)</script>")
           (portal-test--wait-for-page "Input ready" 1)
           (portal-input-focus)
           ,@body)
       (setq unread-command-events nil)
       (portal-hide)
       (when (get-buffer "*portal-web*") (kill-buffer "*portal-web*")))))

(defun portal-input-gui--prefix (&rest strokes)
  "Send a real native prefix followed immediately by STROKES."
  (portal-input-focus)
  (portal-test-native-key 11 (ash 1 18) "\C-b")
  (dolist (stroke strokes) (apply #'portal-test-native-key stroke))
  (let ((event (aref (with-timeout (5 (ert-fail "No shared prefix notification"))
                      (read-key-sequence-vector nil)) 0)))
    (ert-info ((format "Received: %S" event))
      (should (eq (car-safe event) 'portal-input-prefix)))
    (with-timeout (5 (ert-fail "Shared prefix command stalled"))
      (portal-input--dispatch event))))

(ert-deftest portal-input-gui-web-app-owns-escape-and-control-keys ()
  (portal-input-gui--page
    (portal-test-native-key 53 0 "\e")
    (portal-test-native-key 7 (ash 1 18) "\C-x")
    (portal-test-native-key 5 (ash 1 18) "\C-g")
    (should (portal-input--action "focused"))
    (should (portal-excalidraw-gui--js
             "return keys.length===3 && keys[0][0]==='Escape' && keys[1][0]==='x' && keys[1][1] && keys[2][0]==='g' && keys[2][1] && keys.every(k=>k[2]) && ups===3;"))
    (portal-input-gui--prefix '(2 0 "d"))
    (should-not (portal-input--action "focused"))
    (portal-integration-test--emacs-input)
    (portal-input-focus)
    (should (portal-input--action "focused"))))

(ert-deftest portal-input-gui-web-literal-prefix-is-a-real-native-event ()
  (portal-input-gui--page
    (portal-input-gui--prefix (list 11 (ash 1 18) "\C-b"))
    (should (portal-input--action "focused"))
    (should (portal-excalidraw-gui--js
             "return keys.length===1 && keys[0][0]==='b' && keys[0][1] && keys[0][2] && ups===1;"))
    (portal-test-native-key 53 (ash 1 20) "\e")
    (portal-integration-test--emacs-input)))

(ert-deftest portal-input-gui-native-escape-invalidates-unacknowledged-prefix ()
  (portal-input-gui--page
    (portal-test-native-key 11 (ash 1 18) "\C-b")
    (portal-test-native-key 53 (ash 1 20) "\e")
    (should-not (portal-input--action "focused"))
    (should-not (portal-input--action "pending"))
    (let ((event (aref (with-timeout (5 (ert-fail "No pending prefix"))
                        (read-key-sequence-vector nil)) 0)))
      (should (eq (car-safe event) 'portal-input-prefix))
      (portal-input--dispatch event))
    (let ((event (aref (with-timeout (5 (ert-fail "No escape notification"))
                        (read-key-sequence-vector nil)) 0)))
      (should (eq (car-safe event) 'portal-input-escape))
      (portal-input-unfocus))
    (should-not (portal-input--action "focused"))
    (portal-integration-test--emacs-input)))

(ert-deftest portal-input-gui-web-passthrough-releases-prefix-until-escape ()
  (portal-input-gui--page
    (portal-input-passthrough)
    (portal-test-native-key 11 (ash 1 18) "\C-b")
    (should (portal-input--action "passthrough-p"))
    (should (portal-excalidraw-gui--js "return keys.length===1 && keys[0][0]==='b' && keys[0][1];"))
    (portal-test-native-key 53 (ash 1 20) "\e")
    (should-not (portal-input--action "focused"))
    (should-not (portal-input--action "passthrough-p"))
    (portal-input-gui--prefix '(2 0 "d"))
    (should-not (portal-input--action "focused"))))

(ert-deftest portal-input-gui-web-command-selects-and-focuses-terminal ()
  (portal-input-gui--page
    (let ((web-window (selected-window)))
      (select-window (split-window-right))
      (portal-terminal)
      (let ((terminal-id (portal-view-target)))
        (unwind-protect
            (progn
              (select-window web-window)
              (portal-input-gui--prefix '(31 0 "o"))
              (should (eq major-mode 'portal-terminal-mode))
              (should (plist-get (portal-terminal-test--state terminal-id) :focused)))
          (portal-terminal-close-all))))))

(defvar portal-input-gui--ran nil)
(defun portal-input-gui--mark () (interactive) (setq portal-input-gui--ran t))

(ert-deftest portal-input-gui-prefix-key-inside-emacs-gateway-is-not-literal ()
  (portal-input-gui--page
    (use-local-map (copy-keymap portal-mode-map))
    (define-key (current-local-map) [remap list-buffers] #'portal-input-gui--mark)
    (let ((portal-input-gui--ran nil))
      (portal-input-gui--prefix (list 7 (ash 1 18) "\C-x") (list 11 (ash 1 18) "\C-b"))
      (should portal-input-gui--ran)
      (should (portal-input--action "focused"))
      (should (= (portal-excalidraw-gui--js "return keys.length") 0)))))

(provide 'portal-input-gui-tests)
