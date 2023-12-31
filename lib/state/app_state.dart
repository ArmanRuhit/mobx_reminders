import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:mobx/mobx.dart';
import 'package:mobx_reminders/auth/auth_error.dart';
import 'package:mobx_reminders/state/reminder.dart';

part 'app_state.g.dart';

class AppState = _AppState with _$AppState;

abstract class _AppState with Store {
  @observable
  AppScreen currentScreen = AppScreen.login;

  @observable
  bool isLoading = false;

  @observable
  User? currentUser;

  @observable
  AuthError? authError;

  @observable
  ObservableList<Reminder> reminders = ObservableList<Reminder>();

  @computed
  ObservableList<Reminder> get sortedReminders => ObservableList.of(reminders.sorted());

  @action
  void goTo(AppScreen screen) {
    currentScreen = screen;
  }

  @action
  Future<bool> delete(Reminder reminder) async {
    isLoading = true;
    final auth = FirebaseAuth.instance;
    final user = auth.currentUser;
    if (user == null) {
      isLoading = false;
      return false;
    }
    final userId = user.uid;
    final collection = await FirebaseFirestore.instance.collection(userId).get();

    try {
      // delete from firebase
      final firebaseRemnder = collection.docs.firstWhere((element) => element.id == reminder.id);

      await firebaseRemnder.reference.delete();
      // delete from locally
      reminders.removeWhere((element) => element.id == reminder.id);
      return true;
    } catch (_) {
      return false;
    } finally {
      isLoading = false;
    }
  }

  @action
  Future<bool> deleteAccount() async {
    isLoading = true;
    final auth = FirebaseAuth.instance;
    final user = auth.currentUser;
    if (user == null) {
      isLoading = false;
      return false;
    }
    final userId = user.uid;
    try {
      final store = FirebaseFirestore.instance;
      final operation = store.batch();
      final collection = await store.collection(userId).get();
      for (final document in collection.docs) {
        operation.delete(document.reference);
      }
      // delete all reminders of this user in firebase
      await operation.commit();

      // delete the user
      await user.delete();

      // sign out the user
      await auth.signOut();

      currentScreen = AppScreen.login;
      return true;
    } on FirebaseAuthException catch (e) {
      authError = AuthError.from(e);
      return false;
    } catch (_) {
      return false;
    } finally {
      isLoading = false;
    }
  }

  @action
  Future<void> logOut() async {
    isLoading = true;

    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // we are ignoring the errors
    }
    isLoading = false;
    currentScreen = AppScreen.login;
    reminders.clear();
  }

  @action
  Future<bool> createReminder(String text) async {
    isLoading = true;
    final userId = currentUser?.uid;
    if (userId == null) {
      return false;
    }
    final creationDate = DateTime.now();
    // create firebase reminder
    final firebaseReminder = await FirebaseFirestore.instance
        .collection(userId)
        .add({_DocumentKeys.text: text, _DocumentKeys.creationDate: creationDate, _DocumentKeys.isDone: false});

    // create local reminder
    Reminder reminder = Reminder(
      id: firebaseReminder.id,
      creationDate: creationDate,
      text: text,
      isDone: false,
    );

    reminders.add(reminder);
    isLoading = false;
    return true;
  }

  @action
  Future<bool> modify(Reminder reminder, {required bool isDone}) async {
    final userId = currentUser?.uid;
    if (userId == null) {
      return false;
    }

    // update the remote reminder
    final collection = await FirebaseFirestore.instance.collection(userId).get();

    final firebaseReminder = collection.docs.where((element) => element.id == reminder.id).first.reference;

    firebaseReminder.update({_DocumentKeys.isDone: isDone});

    // update the local reminder
    reminders.firstWhere((element) => element.id == reminder.id).isDone = isDone;

    return true;
  }

  @action
  Future<void> initialize() async {
    isLoading = true;
    currentUser = FirebaseAuth.instance.currentUser;

    if (currentUser != null) {
      await _loadReminders();
      currentScreen = AppScreen.reminders;
    } else {
      currentScreen = AppScreen.login;
    }
  }

  @action
  Future<bool> _loadReminders() async {
    final userId = currentUser?.uid;
    if (userId == null) {
      return false;
    }

    final collection = await FirebaseFirestore.instance.collection(userId).get();

    final reminders = collection.docs.map(
      (e) => Reminder(
          id: e.id,
          creationDate: DateTime.parse(e[_DocumentKeys.creationDate] as String),
          text: e[_DocumentKeys.text] as String,
          isDone: e[_DocumentKeys.isDone] as bool),
    );

    this.reminders = ObservableList.of(reminders);

    return true;
  }

  @action
  Future<bool> _registerOrLogin({required LoginOrRegisterFunciton funciton, required String email, required String password}) async {
    authError = null;
    isLoading = true;

    try {
      await funciton(email: email, password: password);
      currentUser = FirebaseAuth.instance.currentUser;
      await _loadReminders();
      return true;
    } on FirebaseAuthException catch (exception) {
      authError = AuthError.from(exception);
      currentUser = null;
      return false;
    } finally {
      isLoading = false;
      if (currentUser != null) {
        currentScreen = AppScreen.reminders;
      }
    }
  }

  @action
  Future<bool> register({required String email, required String password}) =>
      _registerOrLogin(funciton: FirebaseAuth.instance.createUserWithEmailAndPassword, email: email, password: password);

  @action
  Future<bool> login({required String email, required String password}) =>
      _registerOrLogin(funciton: FirebaseAuth.instance.signInWithEmailAndPassword, email: email, password: password);
}

abstract class _DocumentKeys {
  static const text = "text";
  static const creationDate = "creation_date";
  static const isDone = "is_done";
}

typedef LoginOrRegisterFunciton = Future<UserCredential> Function({
  required String email,
  required String password,
});

extension ToInt on bool {
  int toInteger() => this ? 1 : 0;
}

extension Sorted on List<Reminder> {
  List<Reminder> sorted() => [...this]..sort((lhs, rhs) {
      final isDone = lhs.isDone.toInteger().compareTo(rhs.isDone.toInteger());
      if (isDone != 0) {
        return isDone;
      }

      return lhs.creationDate.compareTo(rhs.creationDate);
    });
}

enum AppScreen { login, register, reminders }
