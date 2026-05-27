package android.content;

import java.io.File;

public class ContextWrapper extends Context {
    private Context mBase;

    public ContextWrapper() {
    }

    public ContextWrapper(Context base) {
        mBase = base;
    }

    protected void attachBaseContext(Context base) {
        if (mBase != null) {
            throw new IllegalStateException("Base context already set");
        }
        mBase = base;
    }

    public Context getBaseContext() {
        return mBase;
    }

    @Override
    public SharedPreferences getSharedPreferences(String name, int mode) {
        return mBase != null ? mBase.getSharedPreferences(name, mode) : super.getSharedPreferences(name, mode);
    }

    @Override
    public File getFilesDir() {
        return mBase != null ? mBase.getFilesDir() : super.getFilesDir();
    }

    @Override
    public File getCacheDir() {
        return mBase != null ? mBase.getCacheDir() : super.getCacheDir();
    }

    @Override
    public File getExternalCacheDir() {
        return mBase != null ? mBase.getExternalCacheDir() : super.getExternalCacheDir();
    }

    @Override
    public String getString(int resId) {
        return mBase != null ? mBase.getString(resId) : super.getString(resId);
    }
}
