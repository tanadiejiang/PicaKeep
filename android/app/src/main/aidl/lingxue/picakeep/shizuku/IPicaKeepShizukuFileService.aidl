package lingxue.picakeep.shizuku;

interface IPicaKeepShizukuFileService {
    void destroy();
    List<String> listEntries(String path);
    List<String> listInstalledPackageNames();
    boolean fileExists(String path);
    byte[] readFile(String path);
    void writeFile(String path, in byte[] bytes);
    void deletePath(String path);
    void movePath(String sourcePath, String targetPath);
}
