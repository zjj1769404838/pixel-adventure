/**************************************************************************/
/*  OtaInstaller.java                                                    */
/**************************************************************************/
/*  应用内 APK 安装插件（Godot Android 插件）                             */
/**************************************************************************/
/*  作用：把已下载到本机的 APK 通过 FileProvider 的 content:// URI        */
/*        直接交给系统包安装器，避免「只能跳浏览器手动下载」。            */
/**************************************************************************/
/*  注册方式：在 AndroidManifest.xml 的 <application> 下加                 */
/*      <meta-data android:name="org.godotengine.plugin.v2.OtaInstaller"  */
/*                 android:value="com.godot.game.OtaInstaller" />         */
/**************************************************************************/
/*  返回码契约（与 godot/scripts/ota/ota_installer.gd 一致）：              */
/*      0 = 已拉起系统安装器                                             */
/*      1 = 没有可用安装器 / 文件不可读                                   */
/*      2 = 缺少「安装未知应用」权限                                       */
/*      3 = 用户取消                                                      */
/**************************************************************************/

package com.godot.game;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.util.Log;

import androidx.core.content.FileProvider;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

import java.io.File;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public class OtaInstaller extends GodotPlugin {

	private static final String TAG = "OtaInstaller";

	/** 结果码，与 GDScript 侧 OtaInstaller.Result 对齐。 */
	private static final int RESULT_OK = 0;
	private static final int RESULT_NO_INSTALLER = 1;
	private static final int RESULT_PERM_DENIED = 2;
	private static final int RESULT_USER_CANCELLED = 3;

	public OtaInstaller(Godot godot) {
		super(godot);
	}

	@Override
	public String getPluginName() {
		return "OtaInstaller";
	}

	/**
	 * 拉起系统安装器安装本地 APK。
	 *
	 * @param absPath   APK 绝对路径（通常是 user:// 下的文件）
	 * @param authority FileProvider authority，形如 com.xxx.fileprovider
	 * @return 0 成功 / 1 无安装器或文件无效 / 2 缺未知来源权限 / 3 用户取消
	 */
	@UsedByGodot
	public int installApk(String absPath, String authority) {
		if (absPath == null || absPath.isEmpty()) {
			return RESULT_NO_INSTALLER;
		}
		File apk = new File(absPath);
		if (!apk.isFile() || !apk.canRead()) {
			Log.w(TAG, "installApk: file not readable");
			return RESULT_NO_INSTALLER;
		}

		final int[] outcome = new int[] { RESULT_NO_INSTALLER };
		final CountDownLatch latch = new CountDownLatch(1);

		runOnUiThread(new Runnable() {
			@Override
			public void run() {
				try {
					outcome[0] = doInstall(apk, authority);
				} catch (Throwable t) {
					Log.w(TAG, "installApk failed: " + t.getClass().getSimpleName());
					outcome[0] = RESULT_NO_INSTALLER;
				} finally {
					latch.countDown();
				}
			}
		});

		try {
			latch.await(6, TimeUnit.SECONDS);
		} catch (InterruptedException e) {
			Thread.currentThread().interrupt();
			return RESULT_NO_INSTALLER;
		}
		return outcome[0];
	}

	/**
	 * 打开系统的「安装未知应用」授权页，让用户一键授予权限。
	 *
	 * @return 0 已打开设置页 / 1 打开失败
	 */
	@UsedByGodot
	public int openInstallPermissionSettings() {
		final int[] outcome = new int[] { RESULT_NO_INSTALLER };
		final CountDownLatch latch = new CountDownLatch(1);
		runOnUiThread(new Runnable() {
			@Override
			public void run() {
				try {
					Context ctx = getContext();
					if (ctx == null) {
						return;
					}
					Intent intent = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES);
					if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
						intent.setData(Uri.parse("package:" + ctx.getPackageName()));
					}
					intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
					ctx.startActivity(intent);
					outcome[0] = RESULT_OK;
				} catch (Throwable t) {
					Log.w(TAG, "openInstallPermissionSettings failed: " + t.getClass().getSimpleName());
				} finally {
					latch.countDown();
				}
			}
		});
		try {
			latch.await(6, TimeUnit.SECONDS);
		} catch (InterruptedException e) {
			Thread.currentThread().interrupt();
			return RESULT_NO_INSTALLER;
		}
		return outcome[0];
	}

	/** 真正的安装流程，必须在 UI 线程执行。 */
	private int doInstall(File apk, String authority) {
		Context ctx = getContext();
		if (ctx == null) {
			return RESULT_NO_INSTALLER;
		}
		String realAuthority = (authority == null || authority.isEmpty())
				? ctx.getPackageName() + ".fileprovider"
				: authority;

		PackageManager pm = ctx.getPackageManager();

		// 1) 系统里有没有能装 APK 的组件（通常是系统包安装器）
		Intent probe = new Intent(Intent.ACTION_VIEW);
		probe.setDataAndType(Uri.parse("content://placeholder/" + apk.getName()),
				"application/vnd.android.package-archive");
		List<ResolveInfo> candidates = pm.queryIntentActivities(probe, 0);
		if (candidates == null || candidates.isEmpty()) {
			Log.w(TAG, "doInstall: no package installer available");
			return RESULT_NO_INSTALLER;
		}

		// 2) Android 8.0 起需要「安装未知应用」授权
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !pm.canRequestPackageInstalls()) {
			Log.w(TAG, "doInstall: canRequestPackageInstalls == false");
			return RESULT_PERM_DENIED;
		}

		// 3) 换成 FileProvider 的 content:// URI
		Uri uri;
		try {
			uri = FileProvider.getUriForFile(ctx, realAuthority, apk);
		} catch (Throwable t) {
			// 传入的 authority 与清单不一致时，退回本包名兜底
			try {
				uri = FileProvider.getUriForFile(ctx, ctx.getPackageName() + ".fileprovider", apk);
			} catch (Throwable t2) {
				Log.w(TAG, "doInstall: FileProvider.getUriForFile failed: " + t2.getClass().getSimpleName());
				return RESULT_NO_INSTALLER;
			}
		}

		Intent intent = new Intent(Intent.ACTION_VIEW);
		intent.setDataAndType(uri, "application/vnd.android.package-archive");
		intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
		intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
			intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
		}

		try {
			ctx.startActivity(intent);
		} catch (Throwable t) {
			Log.w(TAG, "doInstall: startActivity failed: " + t.getClass().getSimpleName());
			return RESULT_NO_INSTALLER;
		}
		return RESULT_OK;
	}
}
