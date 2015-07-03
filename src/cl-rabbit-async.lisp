(in-package :cl-rabbit-async)

(declaim (optimize (safety 3) (debug 3) (speed 0)))

(defclass async-channel ()
  ((connection        :type async-connection
                      :initarg :connection
                      :reader async-channel/connection)
   (channel           :type integer
                      :initarg :channel
                      :reader async-channel/channel)
   (message-callbacks :type list
                      :initarg :message-callbacks
                      :initform nil
                      :accessor async-channel/message-callbacks)
   (close-callbacks   :type list
                      :initarg :close-callbacks
                      :initform nil
                      :accessor async-channel/close-callbacks)
   (close-p           :type t
                      :initform nil
                      :accessor async-channel/close-p)))

(defmethod print-object ((obj async-channel) stream)
  (print-unreadable-object (obj stream :type t :identity t)
    (format stream "CHANNEL ~a CLOSED ~s"
            (if (slot-boundp obj 'channel) (slot-value obj 'channel) :not-bound)
            (if (slot-boundp obj 'close-p) (slot-value obj 'close-p) :not-bound))))

(defclass async-connection ()
  ((connection    :type cl-rabbit::connection
                  :initarg :connection
                  :reader async-connection/connection)
   (channels      :type vector
                  :initform (make-array (list 10)
                  :element-type '(or null async-channel)
                  :initial-element nil
                  :adjustable t
                  :fill-pointer nil)
                  :reader async-connection/channels)
   (cmd-fd        :type fixnum
                  :accessor async-connection/cmd-fd)
   (cmd-fd-reader :type fixnum
                  :accessor async-connection/cmd-fd-reader)
   (close-p       :type t
                  :initform nil
                  :accessor async-connection/close-p)
   (b-current     :type (or null integer)
                  :initform nil
                  :accessor async-connection/b-current)
   (b-index       :type integer
                  :initform 0
                  :accessor async-connection/b-index)
   (b-lock        :type t
                  :initform (bordeaux-threads:make-lock "Sync connection lock")
                  :reader async-connection/b-lock)
   (b-condvar     :type t
                  :initform (bordeaux-threads:make-condition-variable :name "Sync connection condvar")
                  :reader async-connection/b-condvar)))

(defun process-unexpected-frame (conn)
  (simple-wait-frame conn))

(defun find-free-channel-index (async-conn)
  (with-accessors ((channels async-connection/channels))
      async-conn
    (let ((pos (position nil channels)))
      (or pos
          (let ((old-size (length channels)))
            (adjust-array channels (* old-size 2) :initial-element nil)
            old-size)))))

(define-condition stop-connection ()
  ())

(defun wait-for-frame (async-conn)
  (log:trace "Waiting for frame on async connection: ~s" async-conn)
  (with-accessors ((channels async-connection/channels)
                   (conn async-connection/connection))
      async-conn
    ;;
    (handler-bind ((cl-rabbit:rabbitmq-library-error
                    (lambda (condition)
                      (when (eq (cl-rabbit:rabbitmq-library-error/error-code condition)
                                :amqp-unexpected-frame)
                        (log:trace "Got unexpected frame")
                        (process-unexpected-frame conn)))))
      ;;
      (let ((envelope (cl-rabbit:consume-message conn)))
        (let* ((channel-id (cl-rabbit:envelope/channel envelope))
               (index (1- channel-id)))
          (labels ((warn-nonexistent-channel ()
                     (log:warn "Message received for closed channel: ~a" channel-id)))
            (if (< index (length channels))
                (let ((async-channel (aref channels index)))
                  (if async-channel
                      (if (not (async-channel/close-p async-channel))
                          (dolist (callback (async-channel/message-callbacks async-channel))
                            (funcall callback envelope))
                          ;; ELSE: We won't deliver messages to a closed channel
                          (warn "Incoming message on closed channel: ~s" async-channel))
                      ;; ELSE: Unused channel
                      (warn-nonexistent-channel)))
                ;; ELSE: Message for unused channel
                (warn-nonexistent-channel))))))))

(defun load-integer-from-fd (in-fd)
  (let ((size (cffi:foreign-type-size :long-long)))
    (cffi:with-foreign-pointer (buf size)
      (let ((result (iolib.syscalls:read in-fd buf size)))
        (cond ((zerop result)
               nil)
              ((= result size)
               (cffi:mem-ref buf :long-long))
              (t
               (error "Unable to read from pipe")))))))

(defun handle-command (async-conn)
  (with-accessors ((b-lock async-connection/b-lock)
                   (b-condvar async-connection/b-condvar)
                   (b-current async-connection/b-current))
      async-conn
    (let ((request-index (load-integer-from-fd (async-connection/cmd-fd-reader async-conn))))
      (log:trace "Got request index: ~s" request-index)
      (if request-index
          (bordeaux-threads:with-lock-held (b-lock)
            (log:trace "Opening gate")
            (when b-current
              (error "The current handler index is not NIL: ~s" b-current))
            (setf b-current request-index)
            (bordeaux-threads:condition-notify b-condvar)
            (log:trace "Waiting for child to finish processing")
            (loop
               while b-current
               do (bordeaux-threads:condition-wait b-condvar b-lock))
            (log:trace "Gate closed"))
          ;; ELSE: When index is NIL, the connection should be stopped
          (signal 'stop-connection)))))

(defun run-sync-loop (async-conn)
  (handler-case
      (let* ((conn (async-connection/connection async-conn))
             (socket-fd (cl-rabbit::get-sockfd conn))
             (in-fd (async-connection/cmd-fd-reader async-conn))
             (event-base (make-instance 'iolib:event-base)))

        (iolib:set-io-handler event-base socket-fd
                              :read (lambda (fd type c)
                                      (declare (ignore fd type c))
                                      (wait-for-frame async-conn)))
        (iolib:set-io-handler event-base in-fd
                              :read (lambda (fd type c)
                                      (declare (ignorable fd type c))
                                      (handle-command async-conn)))
        
        (iolib:set-error-handler event-base in-fd (lambda (&rest aa) (log:error "Got pipe error: ~s" aa)))

        (loop
           if (or (cl-rabbit::data-in-buffer conn)
                  (cl-rabbit::frames-enqueued conn))
           do (wait-for-frame async-conn)
           else do (iolib:event-dispatch event-base :one-shot t)))
    ;; Condition handlers
    (stop-connection ()
      (log:trace "Stopping connection")
      (iolib.syscalls:close (async-connection/cmd-fd-reader async-conn))
      (loop
         for channel across (async-connection/channels async-conn)
         when (and channel (not (async-channel/close-p channel)))
         do (call-close-callbacks channel))
      (cl-rabbit:destroy-connection (async-connection/connection async-conn)))))

(defun get-next-b-index (async-conn)
  (bordeaux-threads:with-lock-held ((async-connection/b-lock async-conn))
    (incf (async-connection/b-index async-conn))))

(defun run-in-sync-thread (async-conn fn)
  (when (async-connection/close-p async-conn)
    (error "Attempt to run command for closed connection"))
  (with-accessors ((b-lock async-connection/b-lock)
                   (b-condvar async-connection/b-condvar)
                   (b-current async-connection/b-current))
      async-conn
    (let ((request-index (get-next-b-index async-conn))
          (size (cffi:foreign-type-size :long-long)))
      (cffi:with-foreign-pointer (buf size)
        (setf (cffi:mem-ref buf :long-long) request-index)
        (iolib.syscalls:write (async-connection/cmd-fd async-conn) buf size))
      (log:trace "Request index ~s sent to server, waiting for gate to open" request-index)
      (bordeaux-threads:with-lock-held (b-lock)
        (loop
           do (log:trace "Still waiting for gate to open, current index is: ~s" b-current)
           until (eql b-current request-index)
           do (bordeaux-threads:condition-wait b-condvar b-lock)))
      (log:trace "Gate opened, proceeding to do stuff")
      (unwind-protect
           (funcall fn)
        (log:trace "Stuff is done, updating current and notify server that the gate is closed")
        (bordeaux-threads:with-lock-held (b-lock)
          (log:trace "managed to get lock so that we can notify the server")
          (setf b-current nil)
          (bordeaux-threads:condition-notify b-condvar))))))

(defmacro with-sync (conn &body body)
  `(run-in-sync-thread ,conn (lambda () ,@body)))

(defun make-async-connection ()
  (let* ((conn (cl-rabbit:new-connection))
         (socket (cl-rabbit:tcp-socket-new conn)))
    (cl-rabbit:socket-open socket "localhost" 5672)
    (cl-rabbit:login-sasl-plain conn "/" "guest" "guest")
    (let ((conn-wrapper (make-instance 'async-connection :connection conn)))
      (trivial-garbage:finalize conn-wrapper
                                (lambda ()
                                  (log:warn "Reference to RabbitMQ connection object lost. Closing.")
                                  #+nil(cl-rabbit:destroy-connection conn)))
      (multiple-value-bind (in-fd out-fd)
          (iolib.syscalls:pipe)
        (setf (async-connection/cmd-fd conn-wrapper) out-fd)
        (setf (async-connection/cmd-fd-reader conn-wrapper) in-fd)
        (bordeaux-threads:make-thread (lambda () (run-sync-loop conn-wrapper))
                                      :name "RabbitMQ listener")
        conn-wrapper))))

(defun close-async-connection (async-conn)
  (when (async-connection/close-p async-conn)
    (error "Connection is already closed"))
  (setf (async-connection/close-p async-conn) t)
  (iolib.syscalls:close (async-connection/cmd-fd async-conn)))

(defun open-channel (async-conn &key message-callback close-callback)
  (with-sync async-conn
    (let* ((index (find-free-channel-index async-conn))
           (channel (1+ index)))
      (cl-rabbit:channel-open (async-connection/connection async-conn) channel)
      (log:trace "Opened channel: ~s" channel)
      (let ((async-channel (make-instance 'async-channel
                                          :connection async-conn
                                          :channel channel
                                          :message-callbacks (if message-callback (list message-callback) nil)
                                          :close-callbacks (if close-callback (list close-callback) nil))))
        (setf (aref (async-connection/channels async-conn) index) async-channel)
        async-channel))))

(defun call-close-callbacks (async-channel)
  (dolist (callback (async-channel/close-callbacks async-channel))
    (handler-case
        (funcall callback async-channel)
      (error (condition) (log:error "Error while calling close callback: ~a" condition)))))

(defun mark-channel-as-closed (async-channel)
  (let ((async-conn (async-channel/connection async-channel)))
    (setf (async-channel/close-p async-channel) t)
    (let ((channels (async-connection/channels async-conn))
          (index (1- (async-channel/channel async-channel))))
      (assert (not (null (aref channels index))))
      (setf (aref channels index) nil)))
  (call-close-callbacks async-channel)
  (log:trace "Channel marked as closed: ~s" async-channel))

(defun close-channel (async-channel &key code)
  (when (async-channel/close-p async-channel)
    (error "Channel is already closed"))
  (let ((async-conn (async-channel/connection async-channel)))
    (with-sync async-conn
      (cl-rabbit:channel-close (async-connection/connection async-conn) (async-channel/channel async-channel)
                               :code code)
      (mark-channel-as-closed async-channel)
      nil)))

(defun verify-server-error (condition async-channel)
  (let ((id (cl-rabbit::rabbitmq-server-error/method condition)))
    (log:trace "Checking error number: ~s" id)
    (cond ((eql id cl-rabbit::amqp-channel-close-method)
           (mark-channel-as-closed async-channel)
           (setf (async-channel/close-p async-channel) t)
           (call-close-callbacks async-channel)
           (log:trace "Channel marked as closed, but still remains in channel list"))
          ((eql id cl-rabbit::amqp-connection-close-method)
           (error "Async disconnection is not implemented")))))

(defmacro mkwrap (async-name name args keys)
  `(defun ,async-name (async-channel ,@args ,@(if keys `(&key ,@keys) nil))
     (let ((async-conn (async-channel/connection async-channel)))
       (when (async-channel/close-p async-channel)
         (error "Attempt to run command for closed channel: ~s" async-channel))
       (with-sync async-conn
         (handler-bind ((cl-rabbit:rabbitmq-server-error (lambda (condition)
                                                           (verify-server-error condition async-channel))))
           (,name (async-connection/connection async-conn)
                  (async-channel/channel async-channel)
                  ,@args ,@(mapcan (lambda (key)
                                     (let ((key-name (if (listp key) (car key) key)))
                                       (list (intern (symbol-name key-name) "KEYWORD") key-name)))
                                   keys)))))))

(mkwrap async-exchange-declare cl-rabbit:exchange-declare (exchange type) (passive durable auto-delete internal arguments))
(mkwrap async-exchange-delete cl-rabbit:exchange-delete (exchange) (if-unused))
(mkwrap async-exchange-unbind cl-rabbit:exchange-unbind () (destination source routing-key))
(mkwrap async-exchange-bind cl-rabbit:exchange-bind () (destination source routing-key arguments))
(mkwrap async-queue-declare cl-rabbit:queue-declare () (queue passive durable exclusive auto-delete arguments))
(mkwrap async-queue-bind cl-rabbit:queue-bind () (queue exchange routing-key arguments))
(mkwrap async-queue-unbind cl-rabbit:queue-unbind () (queue exchange routing-key arguments))
(mkwrap async-queue-purge cl-rabbit:queue-purge (queue) ())
(mkwrap async-queue-delete cl-rabbit:queue-delete (queue) (if-unused if-empty))
(mkwrap async-basic-consume cl-rabbit:basic-consume (queue) (consumer-tag no-local no-ack exclusive arguments))
(mkwrap async-basic-publish cl-rabbit:basic-publish () (exchange routing-key mandatory immediate properties body (encoding :utf-8)))

(defun async-test ()
  (labels ((msgcb (msg)
             (log:info "Msg: ~s" (babel:octets-to-string (cl-rabbit:message/body (cl-rabbit:envelope/message msg)))))
           (closecb (channel)
             (log:info "Channel closed: ~s" channel))
           (mkchannel (c)
             (open-channel c
                           :message-callback #'msgcb
                           :close-callback #'closecb)))

    (let* ((c (make-async-connection)))
      (defparameter *c* c)
      (unwind-protect
           (let ((ch (mkchannel c))
                 (co (open-channel c)))
             (handler-case
                 (async-queue-declare ch :queue "palle" :passive t)
               (cl-rabbit:rabbitmq-server-error (condition)
                 (log:error "Got error of type: ~s, message: ~a"
                            (cl-rabbit:rabbitmq-server-error/reply-code condition)
                            (cl-rabbit:rabbitmq-server-error/message condition))
                 (when (async-channel/close-p ch)
                   (setq ch (mkchannel c))
                   (log:info "Reopened channel: ~s" ch))))
             (log:info "After error, attempting to declare real queue")
             (let ((q (async-queue-declare ch :durable t :exclusive t :auto-delete t)))
               (log:info "Starting consume on input channel")
               (async-basic-consume ch q)
               (log:info "Publishing message on output channel")
               (async-basic-publish co :routing-key q :body "This is a test message"))
             (log:info "Sleeping 1 second before shutting down")
             (sleep 1))
        ;; Unwind form
        (log:info "Closing connection")
        (close-async-connection c)))))
