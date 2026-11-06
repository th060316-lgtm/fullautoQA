import java.io.File;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

class OculixOcrRead {
    public static void main(String[] args) throws Exception {
        if (args.length != 5) {
            throw new IllegalArgumentException("USAGE: jar x y width height");
        }
        URL jar = new File(args[0]).toURI().toURL();
        try (URLClassLoader loader = new URLClassLoader(new URL[]{jar}, ClassLoader.getSystemClassLoader())) {
            Thread.currentThread().setContextClassLoader(loader);
            Class<?> regionClass = Class.forName("org.sikuli.script.Region", true, loader);
            Object region = regionClass
                .getConstructor(int.class, int.class, int.class, int.class)
                .newInstance(
                    Integer.parseInt(args[1]),
                    Integer.parseInt(args[2]),
                    Integer.parseInt(args[3]),
                    Integer.parseInt(args[4])
                );
            Object raw = regionClass.getMethod("text").invoke(region);
            String text = raw == null ? "" : raw.toString();
            String encoded = Base64.getEncoder().encodeToString(text.getBytes(StandardCharsets.UTF_8));
            System.out.println("OCR_BASE64=" + encoded);
        }
    }
}
