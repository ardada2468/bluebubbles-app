import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:bluebubbles/helpers/attachment_downloader.dart';
import 'package:bluebubbles/helpers/constants.dart';
import 'package:bluebubbles/helpers/logger.dart';
import 'package:bluebubbles/helpers/navigator.dart';
import 'package:bluebubbles/helpers/themes.dart';
import 'package:bluebubbles/helpers/utils.dart';
import 'package:bluebubbles/layouts/conversation_list/conversation_list.dart';
import 'package:bluebubbles/layouts/conversation_view/conversation_view.dart';
import 'package:bluebubbles/layouts/setup/failure_to_start.dart';
import 'package:bluebubbles/layouts/setup/setup_view.dart';
import 'package:bluebubbles/layouts/setup/splash_screen.dart';
import 'package:bluebubbles/layouts/setup/upgrading_db.dart';
import 'package:bluebubbles/layouts/testing_mode.dart';
import 'package:bluebubbles/layouts/titlebar_wrapper.dart';
import 'package:bluebubbles/managers/background_isolate.dart';
import 'package:bluebubbles/managers/incoming_queue.dart';
import 'package:bluebubbles/managers/life_cycle_manager.dart';
import 'package:bluebubbles/managers/method_channel_interface.dart';
import 'package:bluebubbles/managers/navigator_manager.dart';
import 'package:bluebubbles/managers/notification_manager.dart';
import 'package:bluebubbles/managers/queue_manager.dart';
import 'package:bluebubbles/managers/settings_manager.dart';
import 'package:bluebubbles/repository/database.dart';
import 'package:bluebubbles/repository/intents.dart';
import 'package:bluebubbles/repository/models/models.dart';
import 'package:bluebubbles/repository/models/objectbox.dart';
import 'package:collection/collection.dart';
import 'package:dynamic_cached_fonts/dynamic_cached_fonts.dart';
import 'package:firebase_dart/firebase_dart.dart';
// ignore: implementation_imports
import 'package:firebase_dart/src/auth/utils.dart' as fdu;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' hide Priority;
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_libphonenumber/flutter_libphonenumber.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;
import 'package:flutter_native_timezone/flutter_native_timezone.dart';
import 'package:get/get.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:local_auth/local_auth.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' show join;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:secure_application/secure_application.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_tray/system_tray.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:universal_html/html.dart' as html;
import 'package:universal_io/io.dart';
import 'package:window_manager/window_manager.dart';

// final SentryClient _sentry = SentryClient(
//     dsn:
//         "https://3123d4f0d82d405190cb599d0e904adc@o373132.ingest.sentry.io/5372783");

bool get isInDebugMode {
  // Assume you're in production mode.
  bool inDebugMode = false;

  // Assert expressions are only evaluated during development. They are ignored
  // in production. Therefore, this code only sets `inDebugMode` to true
  // in a development environment.
  assert(inDebugMode = true);

  return inDebugMode;
}

FlutterLocalNotificationsPlugin? flutterLocalNotificationsPlugin;
late SharedPreferences prefs;
late final FirebaseApp app;
late final Store store;
late final Box<Attachment> attachmentBox;
late final Box<Chat> chatBox;
late final Box<FCMData> fcmDataBox;
late final Box<Handle> handleBox;
late final Box<Message> messageBox;
late final Box<ScheduledMessage> scheduledBox;
late final Box<ThemeEntry> themeEntryBox;
late final Box<ThemeObject> themeObjectBox;
late final Box<AttachmentMessageJoin> amJoinBox;
late final Box<ChatHandleJoin> chJoinBox;
late final Box<ChatMessageJoin> cmJoinBox;
late final Box<ThemeValueJoin> tvJoinBox;
String? recentIntent;
final RxBool fontExistsOnDisk = false.obs;
final RxBool downloadingFont = false.obs;
final RxnDouble progress = RxnDouble();
final RxnInt totalSize = RxnInt();

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      // If there is a bad certificate callback, override it if the host is part of
      // your server URL
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        String serverUrl = getServerAddress() ?? "";
        return serverUrl.contains(host);
      }; // add your localhost detection logic here if you want
  }
}

Future<Null> main() async {
  HttpOverrides.global = MyHttpOverrides();

  // This captures errors reported by the Flutter framework.
  FlutterError.onError = (FlutterErrorDetails details) {
    Logger.error(details.exceptionAsString());
    Logger.error(details.stack.toString());
    if (isInDebugMode) {
      // In development mode simply print to console.
      FlutterError.dumpErrorToConsole(details);
    } else {
      // In production mode report to the application zone to report to
      // Sentry.
      Zone.current.handleUncaughtError(details.exception, details.stack!);
    }
  };

  WidgetsFlutterBinding.ensureInitialized();
  dynamic exception;
  dynamic stacktrace;
  try {
    prefs = await SharedPreferences.getInstance();
    if (!kIsWeb) {
      Directory documentsDirectory =
          //ignore: unnecessary_cast, we need this as a workaround
          (kIsDesktop ? await getApplicationSupportDirectory() : await getApplicationDocumentsDirectory()) as Directory;
      final objectBoxDirectory = Directory(documentsDirectory.path + '/objectbox/');
      final sqlitePath = join(documentsDirectory.path, "chat.db");

      Future<void> initStore({bool saveThemes = false}) async {
        String? storeRef = prefs.getString("objectbox-reference");
        if (storeRef != null) {
          debugPrint("Opening ObjectBox store from reference");
          try {
            store = Store.fromReference(getObjectBoxModel(), base64.decode(storeRef).buffer.asByteData());
          } catch (_) {
            debugPrint("Failed to open store from reference, opening from path");
            store = await openStore(directory: documentsDirectory.path + '/objectbox');
          }
        } else {
          debugPrint("Opening ObjectBox store from path");
          store = await openStore(directory: documentsDirectory.path + '/objectbox');
        }
        attachmentBox = store.box<Attachment>();
        chatBox = store.box<Chat>();
        fcmDataBox = store.box<FCMData>();
        handleBox = store.box<Handle>();
        messageBox = store.box<Message>();
        scheduledBox = store.box<ScheduledMessage>();
        themeEntryBox = store.box<ThemeEntry>();
        themeObjectBox = store.box<ThemeObject>();
        amJoinBox = store.box<AttachmentMessageJoin>();
        chJoinBox = store.box<ChatHandleJoin>();
        cmJoinBox = store.box<ChatMessageJoin>();
        tvJoinBox = store.box<ThemeValueJoin>();
        if (saveThemes && themeObjectBox.isEmpty()) {
          for (ThemeObject theme in Themes.themes) {
            if (theme.name == "OLED Dark") theme.selectedDarkTheme = true;
            if (theme.name == "Bright White") theme.selectedLightTheme = true;
            theme.save(updateIfNotAbsent: false);
          }
        }
      }

      if (!objectBoxDirectory.existsSync() && File(sqlitePath).existsSync()) {
        runApp(UpgradingDB());
        print("Converting sqflite to ObjectBox...");
        Stopwatch s = Stopwatch();
        s.start();
        await DBProvider.db.initDB(initStore: initStore);
        s.stop();
        Logger.info("Migrated in ${s.elapsedMilliseconds} ms");
      } else {
        if (File(sqlitePath).existsSync() && prefs.getBool('objectbox-migration') != true) {
          runApp(UpgradingDB());
          print("Converting sqflite to ObjectBox...");
          Stopwatch s = Stopwatch();
          s.start();
          await DBProvider.db.initDB(initStore: initStore);
          s.stop();
          print("Migrated in ${s.elapsedMilliseconds} ms");
        } else {
          await initStore(saveThemes: true);
        }
      }
    }
    FirebaseDart.setup(
      platform: fdu.Platform.web(
        currentUrl: Uri.base.toString(),
        isMobile: false,
        isOnline: true,
      ),
    );
    var options = FirebaseOptions(
        appId: 'my_app_id',
        apiKey: 'apiKey',
        projectId: 'my_project',
        messagingSenderId: 'ignore',
        authDomain: 'my_project.firebaseapp.com');
    app = await Firebase.initializeApp(options: options);
    await initializeDateFormatting();
    await SettingsManager().init();
    await SettingsManager().getSavedSettings(headless: true);
    if (SettingsManager().settings.immersiveMode.value) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (kIsDesktop && !Platform.isLinux) {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      LaunchAtStartup.instance.setup(
        appName: packageInfo.appName,
        appPath: Platform.resolvedExecutable,
      );
      if (SettingsManager().settings.launchAtStartup.value) {
        await LaunchAtStartup.instance.enable();
      } else {
        await LaunchAtStartup.instance.disable();
      }
    }
    // this is to avoid a fade-in transition between the android native splash screen
    // and our dummy splash screen
    if (!SettingsManager().settings.finishedSetup.value && !kIsWeb && !kIsDesktop) {
      runApp(
        MaterialApp(
          home: SplashScreen(shouldNavigate: false),
          theme: ThemeData(
              backgroundColor: SchedulerBinding.instance!.window.platformBrightness == Brightness.dark
                  ? Colors.black : Colors.white
          )
        )
      );
    }
    Get.put(AttachmentDownloadService());
    if (!kIsWeb && !kIsDesktop) {
      flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
      const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('ic_stat_icon');
      final InitializationSettings initializationSettings =
          InitializationSettings(android: initializationSettingsAndroid);
      await flutterLocalNotificationsPlugin!.initialize(initializationSettings);
      tz.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation(await FlutterNativeTimezone.getLocalTimezone()));
      if (!await GoogleMlKit.nlp.entityModelManager().isModelDownloaded(EntityExtractorOptions.ENGLISH)) {
        GoogleMlKit.nlp.entityModelManager().downloadModel(EntityExtractorOptions.ENGLISH, isWifiRequired: false);
      }
      await FlutterLibphonenumber().init();
    }
    if (kIsDesktop) {
      await WindowManager.instance.setTitle('BlueBubbles (Beta)');
      WindowManager.instance.addListener(DesktopWindowListener());
      doWhenWindowReady(() {
        appWindow.minSize = Size(300, 300);
        appWindow.alignment = Alignment.center;
        appWindow.title = 'BlueBubbles (Beta)';
        appWindow.show();
      });
    }
    if (!kIsWeb) {
      try {
        DynamicCachedFonts.loadCachedFont(
                "https://github.com/tneotia/tneotia/releases/download/ios-font-1/IOS.14.2.Daniel.L.ttf",
                fontFamily: "Apple Color Emoji")
            .then((_) {
          fontExistsOnDisk.value = true;
        });
      } on StateError catch (_) {
        fontExistsOnDisk.value = false;
      }
    }
    await dotenv.load();
  } catch (e, s) {
    exception = e;
    stacktrace = s;
  }

  if (exception == null) {
    ThemeObject light = ThemeObject.getLightTheme();
    ThemeObject dark = ThemeObject.getDarkTheme();
    runApp(Main(
      lightTheme: light.themeData,
      darkTheme: dark.themeData,
    ));
  } else {
    runApp(FailureToStart(e: exception));
    throw Exception("$exception $stacktrace");
  }
}

class DesktopWindowListener extends WindowListener {
  @override
  void onWindowFocus() {
    LifeCycleManager().opened();
  }

  @override
  void onWindowBlur() {
    LifeCycleManager().close();
  }
}

/// The [Main] app.
///
/// This is the entry for the whole app (when the app is visible or not fully closed in the background)
/// This main widget controls
///     - Theming
///     - [NavgatorManager]
///     - [Home] widget
class Main extends StatelessWidget with WidgetsBindingObserver {
  final ThemeData darkTheme;
  final ThemeData lightTheme;

  const Main({Key? key, required this.lightTheme, required this.darkTheme}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AdaptiveTheme(
      /// These are the default white and dark themes.
      /// These will be changed by [SettingsManager] when you set a custom theme
      light: lightTheme.copyWith(
        textSelectionTheme: TextSelectionThemeData(
          selectionColor: lightTheme.primaryColor
        )
      ),
      dark: darkTheme.copyWith(
        textSelectionTheme: TextSelectionThemeData(
          selectionColor: darkTheme.primaryColor
        )
      ),

      /// The default is that the dark and light themes will follow the system theme
      /// This will be changed by [SettingsManager]
      initial: AdaptiveThemeMode.system,
      builder: (theme, darkTheme) => GetMaterialApp(
        /// Hide the debug banner in debug mode
        debugShowCheckedModeBanner: false,

        title: 'BlueBubbles',

        /// Set the light theme from the [AdaptiveTheme]
        theme: theme.copyWith(appBarTheme: theme.appBarTheme.copyWith(elevation: 0.0)),

        /// Set the dark theme from the [AdaptiveTheme]
        darkTheme: darkTheme.copyWith(appBarTheme: darkTheme.appBarTheme.copyWith(elevation: 0.0)),

        /// [NavigatorManager] is set as the navigator key so that we can control navigation from anywhere
        navigatorKey: NavigatorManager().navigatorKey,

        /// [Home] is the starting widget for the app
        home: Home(),

        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.comma): const OpenSettingsIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.keyN): const OpenNewChatCreatorIntent(),
          if (kIsDesktop)
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyN): const OpenNewChatCreatorIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyF): const OpenSearchIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.keyR): const ReplyRecentIntent(),
          if (kIsDesktop)
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyR): const ReplyRecentIntent(),
          LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.keyG): const StartIncrementalSyncIntent(),
          if (kIsDesktop)
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.shift, LogicalKeyboardKey.keyR): const StartIncrementalSyncIntent(),
          if (kIsDesktop)
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyG): const StartIncrementalSyncIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.shift, LogicalKeyboardKey.exclamation): const HeartRecentIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.shift, LogicalKeyboardKey.at): const LikeRecentIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.shift, LogicalKeyboardKey.numberSign): const DislikeRecentIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.shift, LogicalKeyboardKey.dollar): const LaughRecentIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.shift, LogicalKeyboardKey.percent): const EmphasizeRecentIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.shift, LogicalKeyboardKey.caret): const QuestionRecentIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.arrowDown): const OpenNextChatIntent(),
          if (kIsDesktop)
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.tab): const OpenNextChatIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.arrowUp): const OpenPreviousChatIntent(),
          if (kIsDesktop)
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.shift, LogicalKeyboardKey.tab): const OpenPreviousChatIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyI): const OpenChatDetailsIntent(),
          LogicalKeySet(LogicalKeyboardKey.escape): const GoBackIntent(),
        },

        builder: (context, child) => SecureApplication(
          child: Builder(builder: (context) {
            if (SettingsManager().canAuthenticate && !LifeCycleManager().isAlive) {
              if (SettingsManager().settings.shouldSecure.value) {
                SecureApplicationProvider.of(context, listen: false)!.lock();
                if (SettingsManager().settings.securityLevel.value == SecurityLevel.locked_and_secured) {
                  SecureApplicationProvider.of(context, listen: false)!.secure();
                }
              }
            }
            return SecureGate(
              blurr: 0,
              opacity: 1.0,
              lockedBuilder: (context, controller) => Container(
                color: Theme.of(context).backgroundColor,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 20.0),
                        child: Text(
                          "BlueBubbles is currently locked. Please unlock to access your messages.",
                          style: Theme.of(context).textTheme.bodyText1!.apply(fontSizeFactor: 1.5),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      Container(height: 20.0),
                      ClipOval(
                        child: Material(
                          color: Theme.of(context).primaryColor, // button color
                          child: InkWell(
                            child: SizedBox(width: 60, height: 60, child: Icon(Icons.lock_open, color: Colors.white)),
                            onTap: () async {
                              var localAuth = LocalAuthentication();
                              bool didAuthenticate = await localAuth.authenticate(
                                  localizedReason: 'Please authenticate to unlock BlueBubbles', stickyAuth: true);
                              if (didAuthenticate) {
                                controller!.authSuccess(unlock: true);
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              child: child ?? Container(),
            );
          }),
        ),

        defaultTransition: Transition.cupertino,

        getPages: [
          GetPage(page: () => TestingMode(), name: "/testing-mode", binding: TestingModeBinding()),
        ],
      ),
    );
  }
}

/// [Home] widget is responsible for holding the main UI view.
///
/// It renders the main view and also initializes a few managers
///
/// The [LifeCycleManager] also is binded to the [WidgetsBindingObserver]
/// so that it can know when the app is closed, paused, or resumed
class Home extends StatefulWidget {
  Home({Key? key}) : super(key: key);

  @override
  _HomeState createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  ReceivePort port = ReceivePort();
  bool serverCompatible = true;
  bool fullyLoaded = false;

  @override
  void initState() {
    super.initState();

    if (kIsDesktop) {
      initSystemTray();
    }

    // we want to refresh the page rather than loading a new instance of [Home]
    // to avoid errors
    if (LifeCycleManager().isAlive && kIsWeb) {
      html.window.location.reload();
    }

    // Initalize a bunch of managers
    MethodChannelInterface().init();

    // We initialize the [LifeCycleManager] so that it is open, because [initState] occurs when the app is opened
    LifeCycleManager().opened();

    if (!kIsWeb) {
      // This initialization sets the function address in the native code to be used later
      BackgroundIsolateInterface.initialize();
      // Set a reference to the DB so it can be used in another isolate
      prefs.setString("objectbox-reference", base64.encode(store.reference.buffer.asUint8List()));
      // Create the notification in case it hasn't been already. Doing this multiple times won't do anything, so we just do it on every app start
      NotificationManager().createNotificationChannel(
        NotificationManager.NEW_MESSAGE_CHANNEL,
        "New Messages",
        "For new messages retreived",
      );
      NotificationManager().createNotificationChannel(
        NotificationManager.SOCKET_ERROR_CHANNEL,
        "Socket Connection Error",
        "Notifications that will appear when the connection to the server has failed",
      );

      // create a send port to receive messages from the background isolate when
      // the UI thread is active
      final result = IsolateNameServer.registerPortWithName(port.sendPort, 'bg_isolate');
      if (!result) {
        IsolateNameServer.removePortNameMapping('bg_isolate');
        IsolateNameServer.registerPortWithName(port.sendPort, 'bg_isolate');
      }
      port.listen((dynamic data) {
        Logger.info("SendPort received action ${data['action']}");
        if (data['action'] == 'new-message') {
          // Add it to the queue with the data as the item
          IncomingQueue().add(QueueItem(event: IncomingQueue.HANDLE_MESSAGE_EVENT, item: {"data": data}));
        } else if (data['action'] == 'update-message') {
          // Add it to the queue with the data as the item
          IncomingQueue().add(QueueItem(event: IncomingQueue.HANDLE_UPDATE_MESSAGE, item: {"data": data}));
        }
      });
    }

    // Get the saved settings from the settings manager after the first frame
    SchedulerBinding.instance!.addPostFrameCallback((_) async {
      await SettingsManager().getSavedSettings();

      if (SettingsManager().settings.colorsFromMedia.value) {
        try {
          await MethodChannelInterface().invokeMethod("start-notif-listener");
        } catch (_) {}
      }

      if (kIsWeb) {
        String? version = await SettingsManager().getServerVersion();
        int? sum = version?.split(".").mapIndexed((index, e) {
          if (index == 0) return int.parse(e) * 100;
          if (index == 1) return int.parse(e) * 21;
          return int.parse(e);
        }).sum;
        if (version == null || (sum ?? 0) < 42) {
          setState(() {
            serverCompatible = false;
          });
        }

        // override ctrl-f action in browsers
        html.document.onKeyDown.listen((e) {
          if (e.keyCode == 114 || (e.ctrlKey && e.keyCode == 70)) {
            e.preventDefault();
          }
        });
      }

      if (!kIsWeb && !kIsDesktop) {
        // Get sharing media from files shared to the app from cold start
        // This one only handles files, not text
        ReceiveSharingIntent.getInitialMedia().then((List<SharedMediaFile> value) async {
          if (!SettingsManager().settings.finishedSetup.value) return;
          if (value.isEmpty) return;

          // If we don't have storage permission, we can't do anything
          if (!await Permission.storage.request().isGranted) return;

          // Add the attached files to a list
          List<PlatformFile> attachments = [];
          for (SharedMediaFile element in value) {
            attachments.add(PlatformFile(
              name: element.path.split("/").last,
              path: element.path,
              size: 0,
            ));
          }

          if (attachments.isEmpty) return;

          // Go to the new chat creator, with all of our attachments
          CustomNavigator.pushAndRemoveUntil(
            context,
            ConversationView(
              existingAttachments: attachments,
              isCreator: true,
            ),
            (route) => route.isFirst,
          );
        });

        // Same thing as [getInitialMedia] except for text
        ReceiveSharingIntent.getInitialText().then((String? text) {
          if (!SettingsManager().settings.finishedSetup.value) return;
          if (text == null) return;

          // Go to the new chat creator, with all of our text
          CustomNavigator.pushAndRemoveUntil(
            context,
            ConversationView(
              existingText: text,
              isCreator: true,
            ),
            (route) => route.isFirst,
          );
        });

        // Request native code to retreive what the starting intent was
        //
        // The starting intent will be set when you click on a notification
        // This is only really necessary when opening a notification and the app is fully closed
        MethodChannelInterface().invokeMethod("get-starting-intent").then((value) {
          if (!SettingsManager().settings.finishedSetup.value) return;
          if (value['guid'] != null) {
            LifeCycleManager().isBubble = value['bubble'] == "true";
            MethodChannelInterface().openChat(value['guid'].toString());
          }
        });
      }
      if (!SettingsManager().settings.finishedSetup.value) {
        setState(() {
          fullyLoaded = true;
        });
      }
    });

    // Bind the lifecycle events
    WidgetsBinding.instance!.addObserver(this);
  }

  @override
  void didChangeDependencies() async {
    Locale myLocale = Localizations.localeOf(context);
    SettingsManager().countryCode = myLocale.countryCode;
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    // Clean up observer when app is fully closed
    WidgetsBinding.instance!.removeObserver(this);
    super.dispose();
  }

  /// Called when the app is either closed or opened or paused
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Call the [LifeCycleManager] events based on the [state]
    if (state == AppLifecycleState.paused) {
      SystemChannels.textInput.invokeMethod('TextInput.hide').catchError((e) {
        Logger.error("Error caught while hiding keyboard: ${e.toString()}");
      });
      LifeCycleManager().close();
    } else if (state == AppLifecycleState.resumed) {
      LifeCycleManager().opened();
    }
  }

  /// Just in case the theme doesn't change automatically
  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    if (AdaptiveTheme.maybeOf(context)?.mode == AdaptiveThemeMode.system) {
      setState(() {});
    }
  }

  /// Render
  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      systemNavigationBarColor: SettingsManager().settings.immersiveMode.value ? Colors.transparent : Theme.of(context).backgroundColor, // navigation bar color
      systemNavigationBarIconBrightness:
          Theme.of(context).backgroundColor.computeLuminance() > 0.5 ? Brightness.dark : Brightness.light,
      statusBarColor: Colors.transparent, // status bar color
    ));

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        systemNavigationBarColor: SettingsManager().settings.immersiveMode.value ? Colors.transparent : Theme.of(context).backgroundColor, // navigation bar color
        systemNavigationBarIconBrightness:
            Theme.of(context).backgroundColor.computeLuminance() > 0.5 ? Brightness.dark : Brightness.light,
        statusBarColor: Colors.transparent, // status bar color
      ),
      child: Actions(
        actions: {
          OpenSettingsIntent: OpenSettingsAction(context),
          OpenNewChatCreatorIntent: OpenNewChatCreatorAction(context),
          OpenSearchIntent: OpenSearchAction(context),
          OpenNextChatIntent: OpenNextChatAction(context),
          OpenPreviousChatIntent: OpenPreviousChatAction(context),
          StartIncrementalSyncIntent: StartIncrementalSyncAction(),
          GoBackIntent: GoBackAction(context),
        },
        child: Scaffold(
          backgroundColor: context.theme.backgroundColor,
          body: Builder(
            builder: (BuildContext context) {
              if (SettingsManager().settings.finishedSetup.value) {
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.landscapeRight,
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.portraitUp,
                  DeviceOrientation.portraitDown,
                ]);
                if (!serverCompatible && kIsWeb) {
                  return FailureToStart(
                    otherTitle: "Server version too low, please upgrade!",
                    e: "Required Server Version: v0.2.0",
                  );
                }
                return ConversationList(
                  showArchivedChats: false,
                  showUnknownSenders: false,
                );
              } else {
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.portraitUp,
                ]);
                return WillPopScope(
                  onWillPop: () async => false,
                  child: TitleBarWrapper(child: kIsWeb || kIsDesktop
                      ? SetupView() : SplashScreen(shouldNavigate: fullyLoaded)),
                );
              }
            },
          ),
        ),
      ),
    );
  }
}

Future<void> initSystemTray() async {
  final _systemTray = SystemTray();
  String path;
  if (Platform.isWindows) {
    path = p.joinAll([p.dirname(Platform.resolvedExecutable), 'data/flutter_assets/assets/icon', 'icon.ico']);
  } else if (Platform.isMacOS) {
    path = p.joinAll(['AppIcon']);
  } else {
    path = p.joinAll([p.dirname(Platform.resolvedExecutable), 'data/flutter_assets/assets/icon', 'icon.png']);
  }

  // We first init the systray menu and then add the menu entries
  await _systemTray.initSystemTray("BlueBubbles", iconPath: path, toolTip: "BlueBubbles (Beta)");

  await _systemTray.setContextMenu(
    [
      MenuItem(
        label: 'Open App',
        onClicked: () {
          LifeCycleManager().opened();
          appWindow.show();
        },
      ),
      MenuItem(
        label: 'Hide App',
        onClicked: () {
          LifeCycleManager().close();
          appWindow.hide();
        },
      ),
      MenuItem(
        label: 'Close App',
        onClicked: () {
          appWindow.close();
        },
      ),
    ],
  );

  // handle system tray event
  _systemTray.registerSystemTrayEventHandler((eventName) {
    switch (eventName) {
      case 'leftMouseUp':
        appWindow.show();
        break;
    }
  });
}
