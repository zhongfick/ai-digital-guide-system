(function () {
  window.SpeechBridge = {
    recognition: null,

    isSupported: function () {
      return !!(window.SpeechRecognition || window.webkitSpeechRecognition);
    },

    requestMicPermission: function () {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        return Promise.resolve(false);
      }
      return navigator.mediaDevices
        .getUserMedia({ audio: true })
        .then(function (stream) {
          stream.getTracks().forEach(function (track) {
            track.stop();
          });
          return true;
        })
        .catch(function () {
          return false;
        });
    },

    start: function (locale) {
      var self = this;
      var SpeechRecognition =
        window.SpeechRecognition || window.webkitSpeechRecognition;

      if (!SpeechRecognition) {
        self._notify("error", { error: "not_supported" });
        return false;
      }

      if (self.recognition) {
        try {
          self.recognition.abort();
        } catch (e) {}
      }

      self.recognition = new SpeechRecognition();
      self.recognition.lang = locale || "zh-CN";
      self.recognition.continuous = false;
      self.recognition.interimResults = true;
      self.recognition.maxAlternatives = 1;

      self.recognition.onstart = function () {
        self._notify("status", { status: "listening" });
      };

      self.recognition.onresult = function (event) {
        var interim = "";
        var finalText = "";
        for (var i = event.resultIndex; i < event.results.length; i++) {
          var result = event.results[i];
          if (result.isFinal) {
            finalText += result[0].transcript;
          } else {
            interim += result[0].transcript;
          }
        }
        var text = (finalText || interim).trim();
        if (text) {
          self._notify("result", { text: text, isFinal: !!finalText });
        }
      };

      self.recognition.onerror = function (event) {
        self._notify("error", { error: event.error || "unknown" });
      };

      self.recognition.onend = function () {
        self._notify("status", { status: "notListening" });
      };

      try {
        self.recognition.start();
        return true;
      } catch (e) {
        self._notify("error", { error: e.message || "start_failed" });
        return false;
      }
    },

    stop: function () {
      if (this.recognition) {
        try {
          this.recognition.stop();
        } catch (e) {}
      }
    },

    abort: function () {
      if (this.recognition) {
        try {
          this.recognition.abort();
        } catch (e) {}
      }
    },

    _notify: function (event, data) {
      window.postMessage(
        JSON.stringify({
          type: "speechBridge",
          event: event,
          data: data,
        }),
        "*"
      );
    },
  };
})();
