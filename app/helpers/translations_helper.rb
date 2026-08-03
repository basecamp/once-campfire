module TranslationsHelper
  TRANSLATIONS = {
    email_address:  { "🇺🇸": "Enter your email address", "🇪🇸": "Introduce tu correo electrónico", "🇫🇷": "Entrez votre adresse courriel", "🇮🇳": "अपना ईमेल पता दर्ज करें", "🇩🇪": "Geben Sie Ihre E-Mail-Adresse ein", "🇧🇷": "Insira seu endereço de email", "🇯🇵": "メールアドレスを入力してください" },
    password: { "🇺🇸": "Enter your password", "🇪🇸": "Introduce tu contraseña", "🇫🇷": "Saisissez votre mot de passe", "🇮🇳": "अपना पासवर्ड दर्ज करें", "🇩🇪": "Geben Sie Ihr Passwort ein", "🇧🇷": "Insira sua senha", "🇯🇵": "パスワードを入力してください" },
    update_password: { "🇺🇸": "Change password", "🇪🇸": "Cambiar contraseña", "🇫🇷": "Changer le mot de passe", "🇮🇳": "पासवर्ड बदलें", "🇩🇪": "Passwort ändern", "🇧🇷": "Alterar senha", "🇯🇵": "パスワードを変更" },
    user_name: { "🇺🇸": "Enter your name", "🇪🇸": "Introduce tu nombre", "🇫🇷": "Entrez votre nom", "🇮🇳": "अपना नाम दर्ज करें", "🇩🇪": "Geben Sie Ihren Namen ein", "🇧🇷": "Insira seu nome", "🇯🇵": "お名前を入力してください" },
    account_name: { "🇺🇸": "Name this account", "🇪🇸": "Nombre de esta cuenta", "🇫🇷": "Nommez ce compte", "🇮🇳": "इस खाते का नाम दें", "🇩🇪": "Benennen Sie dieses Konto", "🇧🇷": "Dê um nome a essa conta", "🇯🇵": "アカウントに名前を付ける" },
    room_name: { "🇺🇸": "Name the room", "🇪🇸": "Nombrar la sala", "🇫🇷": "Nommez la salle", "🇮🇳": "कमरे का नाम दें", "🇩🇪": "Geben Sie dem Raum einen Namen", "🇧🇷": "Dê um nome a essa sala", "🇯🇵": "ルームに名前を付ける" },
    invite_message: { "🇺🇸": "Welcome to Campfire. To invite some people to chat with you, share the join link below.", "🇪🇸": "Bienvenido a Campfire. Para invitar a algunas personas a chatear contigo, comparte el enlace de unión que se encuentra a continuación.", "🇫🇷": "Bienvenue sur Campfire. Pour inviter des personnes à discuter avec vous, partagez le lien pour rejoindre ci-dessous.", "🇮🇳": "Campfire में आपका स्वागत है। अधिक लोगों को चैट के लिए आमंत्रित करने के लिए, नीचे जुड़ने का लिंक साझा करें।", "🇩🇪": "Willkommen bei Campfire. Um einige Personen zum Chatten einzuladen, teilen Sie den unten stehenden Beitrittslink.", "🇧🇷": "Boas vindas ao Campfire. Para convidar pessoas para conversarem com você, compartilhe o link de convite abaixo.", "🇯🇵": "Campfireへようこそ。他の人をチャットに招待するには、下記の参加リンクを共有してください。" },
    incompatible_browser_messsage: { "🇺🇸": "Upgrade to a supported web browser. Campfire requires a modern web browser. Please use one of the browsers listed below and make sure auto-updates are enabled.", "🇪🇸": "Actualiza a un navegador web compatible. Campfire requiere un navegador web moderno. Utiliza uno de los navegadores listados a continuación y asegúrate de que las actualizaciones automáticas estén habilitadas.", "🇫🇷": "Mettez à jour vers un navigateur web pris en charge. Campfire nécessite un navigateur web moderne. Veuillez utiliser l'un des navigateurs répertoriés ci-dessous et assurez-vous que les mises à jour automatiques sont activées.", "🇮🇳": "समर्थित वेब ब्राउज़र में अपग्रेड करें। Campfire को एक आधुनिक वेब ब्राउज़र की आवश्यकता है। कृपया नीचे सूचीबद्ध ब्राउज़रों में से कोई एक का उपयोग करें और सुनिश्चित करें कि स्वचालित अपडेट्स सक्षम हैं।", "🇩🇪": "Aktualisieren Sie auf einen unterstützten Webbrowser. Campfire erfordert einen modernen Webbrowser. Verwenden Sie bitte einen der unten aufgeführten Browser und stellen Sie sicher, dass automatische Updates aktiviert sind.", "🇧🇷": "Atualize para um navegador compatível. O Campfire requer um navegador moderno. Por favor, use um dos navegadores listados abaixo e certifique-se de que as atualizações automáticas estão ativadas.", "🇯🇵": "サポートされたウェブブラウザーにアップグレードしてください。Campfireはモダンなウェブブラウザーが必要です。下記のブラウザーのいずれかを使用し、自動更新が有効になっていることを確認してください。" },
    bio: { "🇺🇸": "Enter a few words about yourself.", "🇪🇸": "Ingresa algunas palabras sobre ti mismo.", "🇫🇷": "Saisissez quelques mots à propos de vous-même.", "🇮🇳": "अपने बारे में कुछ शब्द लिखें.", "🇩🇪": "Geben Sie ein paar Worte über sich selbst ein.", "🇧🇷": "Insira alguma palavras sobre você.", "🇯🇵": "ご自分について簡単に記入してください。" },
    webhook_url: { "🇺🇸": "Webhook URL", "🇪🇸": "URL del Webhook", "🇫🇷": "URL du webhook", "🇮🇳": "वेबहुक URL", "🇩🇪": "Webhook-URL", "🇧🇷": "URL do Webhook", "🇯🇵": "Webhook URL" },
    chat_bots: { "🇺🇸": "Chat bots. With Chat bots, other sites and services can post updates directly to Campfire.", "🇪🇸": "Bots de chat. Con los bots de chat, otros sitios y servicios pueden publicar actualizaciones directamente en Campfire.", "🇫🇷": "Bots de discussion. Avec les bots de discussion, d'autres sites et services peuvent publier des mises à jour directement sur Campfire.", "🇮🇳": "चैट बॉट। चैट बॉट के साथ, अन्य साइटों और सेवाएं सीधे कैम्पफायर में अपडेट पोस्ट कर सकती हैं।", "🇩🇪": "Chat-Bots. Mit Chat-Bots können andere Websites und Dienste Updates direkt in Campfire veröffentlichen.", "🇧🇷": "Chat bots. Com Chat bots, outros sites e serviços podem postar atualizações diretamente no Campfire.", "🇯🇵": "チャットボット。チャットボットを使用すると、他のサイトやサービスがCampfireに直接更新情報を投稿できます。" },
    bot_name: { "🇺🇸": "Name the bot", "🇪🇸": "Nombrar al bot", "🇫🇷": "Nommer le bot", "🇮🇳": "बॉट का नाम दें", "🇩🇪": "Benenne den Bot", "🇧🇷": "Dê um nome ao bot", "🇯🇵": "ボットに名前を付ける" },
    custom_styles: { "🇺🇸": "Add custom CSS styles. Use Caution: you could break things.", "🇪🇸": "Agrega estilos CSS personalizados. Usa precaución: podrías romper cosas.", "🇫🇷": "Ajoutez des styles CSS personnalisés. Utilisez avec précaution : vous pourriez casser des choses.", "🇮🇳": "कस्टम CSS स्टाइल जोड़ें। सावधानी बरतें: आप चीज़ों को तोड़ सकते हैं।", "🇩🇪": "Fügen Sie benutzerdefinierte CSS-Stile hinzu. Vorsicht: Sie könnten Dinge kaputt machen.", "🇧🇷": "Adicione estilos CSS personalizados. Use com cuidado: você pode quebrar coisas.", "🇯🇵": "カスタムCSSスタイルを追加。注意: サイトが壊れる可能性があります。" }
  }

  def translations_for(translation_key)
    tag.dl(class: "language-list") do
      TRANSLATIONS[translation_key].map do |language, translation|
        concat tag.dt(language)
        concat tag.dd(translation, class: "margin-none")
      end
    end
  end

  def translation_button(translation_key)
    tag.details(class: "position-relative", data: { controller: "popup", action: "keydown.esc->popup#close toggle->popup#toggle click@document->popup#closeOnClickOutside", popup_orientation_top_class: "popup-orientation-top" }) do
      tag.summary(class: "btn") do
        concat image_tag("globe.svg", size: 20, aria: { hidden: "true" }, class: "color-icon")
        concat tag.span("Translate", class: "for-screen-reader")
      end +
      tag.div(class: "language-list-menu shadow", data: { popup_target: "menu" }) do
        translations_for(translation_key)
      end
    end
  end
end
